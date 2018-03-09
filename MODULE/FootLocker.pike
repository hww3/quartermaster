inherit Filesystem.Monitor.basic;

protected mapping configuration;

protected ADT.Queue delete_queue = ADT.Queue();
protected ADT.Queue create_queue = ADT.Queue();
protected ADT.Queue exists_queue = ADT.Queue();
protected ADT.Queue change_queue = ADT.Queue();
protected ADT.History history = ADT.History(25);

protected Thread.Farm workers = Thread.Farm();

protected int do_not_process = 0;
protected int thread_running = 0;
protected int should_quit = 1;

protected int repository_state;
protected int processing_state;

protected string dir;
protected float commit_coalesce_period = 0.75;
protected int stable_time = 2;

protected Public.Protocols.XMPP.client xmpp_client;
protected Thread.Thread process_thread;
protected object delegate; // control delegate

constant HISTORY_TYPE_INFO = 0;
constant HISTORY_TYPE_ERROR = 1;

constant REPOSITORY_STATE_CLEAN = 0;
constant REPOSITORY_STATE_ERROR = 1;

constant PROCESSING_STATE_IDLE = 0;
constant PROCESSING_STATE_PENDING = 1;
constant PROCESSING_STATE_RECORDING = 2;
constant PROCESSING_STATE_SENDING = 3;
constant PROCESSING_STATE_RECEIVING = 4;

constant history_types = ([
  HISTORY_TYPE_INFO: "INFO",
  HISTORY_TYPE_ERROR: "ERROR"
]);

constant repository_states = ([ 
  REPOSITORY_STATE_CLEAN : "CLEAN",
  REPOSITORY_STATE_ERROR : "ERROR",
]);

constant processing_states = ([
  PROCESSING_STATE_IDLE: "IDLE",
  PROCESSING_STATE_PENDING: "PENDING",
  PROCESSING_STATE_RECORDING: "RECORDING",
  PROCESSING_STATE_SENDING: "SENDING",
  PROCESSING_STATE_RECEIVING: "RECEIVING",
]);

protected void create(mapping config, object control_delegate) {
  configuration = config;
  configuration->dir = Stdio.append_path(configuration->dir, "")[0..<1];

  if(!configuration->dir)
    werror("no directory specified in FootLocker configuration\n");
  
  if(has_index(configuration, "commit_coalesce_period")) {
    commit_coalesce_period = (float)configuration->commit_coalesce_period;
    werror("setting commit coalesce period to %f seconds.\n", commit_coalesce_period);
  }
  
  if(has_index(configuration, "stable_time")) {
    stable_time = (int)configuration->stable_time;
    werror("setting stable time to %d seconds.\n", stable_time);
  }
  
  delegate = control_delegate;
  
  workers->set_max_num_threads(4); // should be plenty for our purposes.
  ::create(0,0,stable_time); 
}

protected void set_processing_state(int st) {
  int c = 0;
  if(st != processing_state) c = 1;
  processing_state = st;
  if(c) status_changed();
}

protected void set_repository_state(int st) {
  int c = 0;
  if(st != repository_state) c = 1;
  repository_state = st;
  if(c) status_changed();
}

protected string get_processing_state_name() {
  return processing_states[processing_state];
}

protected string get_repository_state_name() {
  return repository_states[repository_state];
}

protected void add_history(int history_type, string descr) {
  history->push((["type": history_types[history_type], "time": time(), "message": descr]));
}

array(mapping) get_history() {
  return values(history);
}

void setup() {

  // first, create the directory if it doesn't exist.
  if(!Stdio.exist(configuration->dir)) {
    if(!mkdir(configuration->dir))
      throw(Error.Generic("Unable to creeate footlocker directory " + configuration->dir));
  } else if(!Stdio.is_dir(configuration->dir)) {
    throw(Error.Generic("Footlocker directory " + configuration->dir + " exists but is not a folder.\n"));
  }
  dir = System.resolvepath(configuration->dir);

  verify_local_repository();
  monitor(dir, Filesystem.Monitor.basic.MF_RECURSE);
  call_out(setup_xmpp_link, 0);
}

protected void setup_xmpp_link() {

  xmpp_client = Public.Protocols.XMPP.client(configuration->xmpp_url);
  xmpp_client->set_connect_callback(xmpp_connected);
  xmpp_client->set_client_name(gethostname() + "-" + configuration->source);
  xmpp_client->begin();
}

void xmpp_connected(object client) {
  werror("xmpp_connected.\n");
  xmpp_client->set_presence(Public.Protocols.XMPP.PRESENCE_CHAT, "hello");
  xmpp_client->set_message_callback(got_xmpp_msg);
} 

void got_xmpp_msg(mapping message) {
  if(message->from == xmpp_client->jid) { 
//    werror("ignoring my own message.\n");
    return;
  }
  mixed msg = Standards.JSON.decode(message->body || "{}");
  
  werror("received message: %O\n", msg);
  
  if(msg->event == "changes_pushed" && msg->source == configuration->source) {
   pull_incoming_changes(); 
  }
}

protected void changes_pushed() {

  xmpp_client->send_message(Standards.JSON.encode((["event": "changes_pushed", "source": configuration->source])), "", xmpp_client->user + "@" + xmpp_client->server);
}

void start_watch() {
  set_nonblocking(2);
}

protected void run_process_thread()
{
//werror("starting run_process_thread()\n");
  thread_running = 1;
  while(!should_quit)
  {
// werror("running process_entries()\n");
    catch(process_entries());
  }
  thread_running = 0;
//  werror("run_process_thread exiting.\n");
}

void start_processing_events(int|void dont_force) {
    if(dont_force &&  do_not_process) return; // if we have asked to not process events, do not override.
    if(thread_running) return; // don't start multiple processing threads.
    do_not_process = 0;
    should_quit = 0;
    process_thread = Thread.Thread(run_process_thread);
}

void stop_processing_events() {
  should_quit = 1;
  do_not_process = 1;
}

void verify_local_repository();

void add_new_file(string path, int|void advisory);
void remove_file(string path);
void save_changed_file(string path, Stdio.Stat st);
void pull_incoming_changes();

protected void process_entries() {
  int processed_stuff = 0;
  
  while(!delete_queue->is_empty()) {
    if(should_quit) return;
    processed_stuff = 1;
    remove_file(@delete_queue->read());
  }

  while(!exists_queue->is_empty()) {
    if(should_quit) return;
    processed_stuff = 1;
    add_new_file(@exists_queue->read(), 1);      
  }

  while(!create_queue->is_empty()) {
    if(should_quit) return;
    processed_stuff = 1;
    add_new_file(@create_queue->read());      
  }

  while(!change_queue->is_empty()) {
    if(should_quit) return;
    processed_stuff = 1;
    save_changed_file(@change_queue->read());
  }

  if(!processed_stuff)
    should_quit = 1;
}

void data_changed(string path) {
  werror("data_changed(%O)\n", path);
}

void stable_data_change(string path, Stdio.Stat st) {
  werror("stable_data_change(%O, %O)\n", path, st);
  change_queue->write(({path, st}));
  if(!thread_running) start_processing_events(1);
}

void file_deleted(string path, Stdio.Stat st)
{
  werror("file_deleted(%O)\n", path);
  delete_queue->write(({path, st}));
  if(!thread_running) start_processing_events(1);
}
  
void file_created(string path, Stdio.Stat st)
{
  werror("file_created(%O, %O)\n", path, st);
  create_queue->write(({path, st}));
  if(!thread_running) start_processing_events(1);
}
  
void file_exists(string path, Stdio.Stat st)
{
   werror("file_exists(%O, %O)\n", path, st);
   exists_queue->write(({path, st}));
  if(!thread_running) start_processing_events(1);
}

mapping status() {
  return (["repository_state": get_repository_state_name(), "processing_state": get_processing_state_name(),
            "path": dir, "history": get_history()]);
}

void status_changed() {
  delegate->status_changed(this, (["repository_state": get_repository_state_name(), "processing_state": get_processing_state_name(),]));
}

void shutdown() {
  int i = 0;
  stop_processing_events();
  while(processing_state != PROCESSING_STATE_IDLE) {
    if(!i)
      werror("Processing state is %s, waiting up to 10 seconds.\n", get_processing_state_name());
    sleep(1);
    i++;
    if(i > 9) {
      werror("Processing state is %s, shutdown proceeding. This may result in inconsistent data.\n", get_processing_state_name());
      break;
    }
  }
}