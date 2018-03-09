
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

mapping footlockers = ([]);

protected void create(array(string) args)
 {
    ::create(args);
 }

int main(int argc, array(string) argv) {
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
    mixed e = catch(Stdio.File(logfile, "cwa"));
    if(e) {
      werror("Unable to create log file: %s\n", Error.mkerror(e)->message());
      return 2;
    }
    
    configfile = config->configfile;
    if(!Stdio.is_file(configfile)) {
      werror("Error: config file %s does not exist\n", configfile);
      return 1;
    }
    
    write("Quartermaster %s starting\n", QUARTERMASTER_VERSION);

    if(enter_background(daemon_mode, logfile)) {
      return 0;
    } 

  load_preferences();
  call_out(configure_footlockers, 1);
  return -1;
}

void display_help() {
  write("usage: quartermaster [-v|--version] [-h|--help] [-f yyy|--configfile=yyyy] [-d|--daemon] [-lxxxx|-logfile=xxxx]\n");
}

void display_version() {
  write("quartermaster version %s\n", QUARTERMASTER_VERSION);
}

void load_preferences()
{
   string f=Stdio.read_file(configfile);
   if(!f) error("Unable to read config file " + configfile + "\n");
   else write("Read configuration from " + configfile + "\n");
   mapping p=Config.read(f);
   prefs=p;
}

void configure_footlockers() {
  foreach(glob("footlocker_*", indices(prefs));; string config_key) {
    write("Configuring footlocker from %s\n", config_key);
    mapping fl_config = prefs[config_key];
    
    switch(fl_config->type) {
      case "hg":
        write("creating footlocker for hg source.\n");
        FootLocker fl = HgFootLocker(fl_config);
        fl->setup();
        footlockers[config_key] = fl;
        fl->start_watch();
        break;
      default:
        werror("unknown footlocker type " + fl_config->type + ". Not configuring.\n");
    }
  }
}