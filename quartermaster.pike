
inherit Application.Backgrounder;

constant QUARTERMASTER_VERSION = "0.1";

mapping config_defaults = ([
    "configfile": "quartermaster.conf",
    "logfile": "/var/log/quartermaster.log",
    "daemon": 0,
    "help": 0,
    "version": 0
  ]);
  
string configfile;
string logfile;
mapping prefs;
int shutting_down = 0;

ControlSocket control_socket;

mapping footlockers = ([]);

protected void create(array(string) args)
 {
    ::create(args);
 }

public int main(int argc, array(string) argv) {
  int daemon_mode=0;

  array args=Getopt.find_all_options(argv, ({ 
      ({"daemon", Getopt.NO_ARG, ({"-d", "--daemon"}) }),
      ({"help", Getopt.NO_ARG, ({"-h", "--help"}) }),
      ({"version", Getopt.NO_ARG, ({"-v", "--version"}) }),
      ({"configfile", Getopt.HAS_ARG, ({"-f", "--configfile"}) }), 
      ({"logfile", Getopt.HAS_ARG, ({"-l", "--logfile"}) }) 
    }) );

  mapping config = ([]);
  
  foreach(args, array arg) {
    switch(arg[0]) {
      case "daemon":
        config->daemon = 1;
        break;
      case "help":
        config->help = 1;
        break;
      case "version":
        config->version = 1;
        break;
      case "logfile":
        config->logfile = arg[1];
        break;
      case "configfile":
        config->configfile = arg[1];
        break;
      }
    }

    config = config_defaults + config; // we should get a fully populated config object with this.
    
    
    if(config->help) {
      display_help();
      return 0;
    }

    if(config->version) {
      display_version();
      return 0;
    }

    if(config->daemon) {
      daemon_mode=1;
      catch(System.setsid());
    }
    
    logfile = config->logfile;
    
    configfile = config->configfile;
    if(!Stdio.is_file(configfile)) {
      werror("Error: config file %s does not exist\n", configfile);
      return 1;
    }

	if(daemon_mode) {
	    mixed e = catch(Stdio.File(logfile, "cwa"));
	    if(e) {
	      werror("Unable to create log file: %s\n", Error.mkerror(e)->message());
	      return 2;
	    }
	
	}
    
    write("Quartermaster %s starting\n", QUARTERMASTER_VERSION);

    if(enter_background(daemon_mode, logfile)) {
      return 0;
    } 

  load_preferences();
  call_out(configure_control_socket, 1);
  call_out(configure_footlockers, 1);
  
  signal(signum("SIGINT"), shutdown);
  return -1;
}

protected void display_help() {
  write("usage: quartermaster [-v|--version] [-h|--help] [-f yyy|--configfile=yyyy] [-d|--daemon] [-lxxxx|-logfile=xxxx]\n");
}

protected void display_version() {
  write("quartermaster version %s\n", QUARTERMASTER_VERSION);
}

protected void load_preferences()
{
   string f=Stdio.read_file(configfile);
   if(!f) error("Unable to read config file " + configfile + "\n");
   else write("Read configuration from " + configfile + "\n");
   mapping p=Config.read(f);
   prefs=p;
}

protected void configure_control_socket() {
  string sock_path;
  if(prefs->global && (sock_path = prefs->global->control_socket)) {
    werror("creating control socket at %s.\n", sock_path);
    control_socket = ControlSocket(sock_path, controlsocket_delegate(this));
  }
}

protected void configure_footlockers() {
  foreach(glob("footlocker_*", indices(prefs));; string config_key) {
    write("Configuring footlocker from %s\n", config_key);
    mapping fl_config = prefs[config_key];
    
    switch(fl_config->type) {
      case "hg":
        write("creating footlocker for hg source.\n");
        FootLocker fl = HgFootLocker(fl_config, footlocker_delegate(this));
        fl->setup();
        footlockers[config_key] = fl;
        fl->start_watch();
        break;
      default:
        werror("unknown footlocker type " + fl_config->type + ". Not configuring.\n");
    }
  }
}
  
mapping status() {
  mapping fls = ([]);
  foreach(footlockers; string key; object fl) {
    fls[key] = fl->status();
  }
    
  return fls;
}

mapping shutdown() {
  if(shutting_down) {
    werror("already shutting down\n");
    return (["error": "SHUTDOWN_PENDING"]);
  }

  return do_shutdown();
}

mapping do_shutdown() {
  shutting_down = 1;
  
  werror("shutdown requested\n");

  foreach(footlockers; string key; object fl) {
    werror("requesting shutdown of %s\n", key);
    fl->shutdown();
  }
  
  call_out(exit, 1.0, 0);
  return (["result": "OK"]);
}

void status_changed(object footlocker, mapping status) {
  if(control_socket) {
    string flname = search(footlockers, footlocker);
    control_socket->status_changed(flname, status);
  }
}

class footlocker_delegate(object controller) {
  void status_changed(object footlocker, mapping status) {
     controller->status_changed(footlocker, status);
  }
}

class controlsocket_delegate(object controller) {

  mapping status() {
    return controller->status();
  }
  
  mapping shutdown() {
    return controller->shutdown();
  }
}