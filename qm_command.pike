

int main(int argc, array(string) argv) {
  string socket_path;
  
  if(argc < 3) {
    werror("Usage: qm_command /path/to/socket [status|watch|shutdown]\n");
    return 1;
  }
  
  socket_path = argv[1];
  string command = argv[2];
  
  if(!(<"status", "watch", "shutdown">)[command]) {
    werror("Usage: qm_command /path/to/socket [status|watch|shutdown]\n");
    return 1;
  }
  
  Stdio.File socket = Stdio.File();
  write("Connecting to QuarterMaster control socket %s.\n", socket_path);
   
  if(!socket->connect_unix(socket_path)) {
    werror("Unable to open socket.\n");
    return 2;
  }
  
  int repeat = 0;

  if(command == "watch") {
    repeat = 1;    
  } else {
    socket->write("{\"cmd\": \"" + command + "\"}");
  }

  string resp;
  do {
    resp = socket->read(1024, 1);
    if(resp)
      write(resp + "\n");
  } while(repeat && sizeof(resp));
  
  return 0;
}