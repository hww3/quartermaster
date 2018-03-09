//! Backgrounder is a convenience class that makes it straightforward to write 
//! applications that  detatch from the console and enter the background (for example,
//! daemon-like processes). The idea is that the main class which wishes to become
//! a daemon should inherit this class, being sure that its create() function calls
//! @[::create()], see the note below and example.
//!
//! @note 
//! This class will use @[fork()] on systems where it is available, however fork-like 
//! semantics should not be assumed, as other methods are employed when fork() is not
//! available in order to achieve the goal of detaching from the controlling console.
//!
//! Some systems, notably Windows, don't have @[fork()], so we must spawn a new
//! pike process from the beginning. This class handles this madness automatically,
//! though any class that inherits this must explicitly call @[create()] with the command line
//! arguments passed to it, so that it knows how to spawn the program correctly.
//! 
//! Programs using this class should be aware that on non-fork-enabled systems, additional
//! command-line arguments will be passed to the new process so that the backgrounding state
//! is available. Because of this, argument parsing code should be tolerant of extra arguments
//! in the form of --tools-application-backgrounder*.
//!
//! in this situation, this class will do some magic to make everything work, however
//! the spawned background program will run everything up to the point that 
//! @[enter_background()], so everyhing before @[enter_background()] be kept to an 
//! absolute minimum, such as limiting activities to parsing (but not acting on) command 
//! line arguments. There are likely other "gotchas" as well, so be careful out there!
//!
//! @example
//! inherit Tools.Application.Backgrounder;
//!
//! int should_background = 0;
//! string logfile = "daemon.log";
//!
//! protected void main(array(string) args)
//! {
//!    ::create(args)
//! }
//!
//! void do_parse_args(array(string) args)
//! {
//!    // let's pretend we've parsed arguments...
//!    should_background = 1;
//! }
//!
//! int main(int argc, array(string argv)
//! {
//!    // first, we should parse any argumensts, and decide whether backgrounding is desired.
//!       do_parse_args(argc)
//! 
//!    // second, if appropriate, enter the background.
//!    if(enter_background(should_background, logfile))
//!    {
//!       return 0;
//!    }
//! }

private int in_child = 0;
private object child_pid;

array(string) argv = ({});
array(string) bootargs = ({});
class pidlet
{
  function pid = getpid;
}


//!  @param _args
//!  The arguments used to run this command line program
//!  @param _bootargs
//!  If _args is a subset of the full command line arguments (such as would be received by a 
//!  Tools.Standalone utility), then this parameter should contain the extra arguments that would
//!  be required to get this program to be run (such as ({"-x", "mytool"})).
//!
protected void create(array(string) _args, array(string)|void _bootargs)
{
//  argv = _args; 
  if(_bootargs)
    bootargs = _bootargs;
    
  if(search(_args||({}), "--tools-application-backgrounder=go-background") != -1)
  {
    string logfile;
    in_child = 1;
    child_pid = pidlet();
    
    foreach(_args||({});;string clo)
    {
      if(has_prefix(clo, "--tools-application-backgrounder"))
      {
        string _logfile;
        sscanf("--tools-application-backgrounder=%s", clo, _logfile);
        if(_logfile) 
          logfile = _logfile;
      }
      else
      {
        argv += ({clo});
      }
    }
    close_stdio(logfile);
  }
  else argv = _args;
}

//! Cause this program to enter the background.
//! 
//! @param should_we
//!   an integer that determines whether the process should be backgrounded or not
//!
//! @param logfile
//!   a string pointing to a log file that stdout and stderr will be written to
//!
//! @returns
//!    1 if the parent has successfully backgrounded a child, 0 if already in the background 
//!    or don't need to enter the background.
//!
//! @note
//!   when this function returns true (1), this means we're in the foreground process (and a 
//!   daemon was spawned and should therefore @[exit()] the program as expeditiously as 
//!   possible. Otherwise, the process is in the background and should continue on with normal 
//!   operations. 
//! 
//!   If, after calling @[enter_background()], an application needs to know whether the 
//!   application is operating as a daemon or not, @[in_background()] may be used.
//!
//!  @note
//!    because of the way certain functionality is emulated on systems without @[fork()], 
//!    applications using this class should be careful to limit the amount of work performed
//!    before this method is called. Specifically, anything performed should be "side-effect"
//!    free, as the work will effectively be performed twice. Thus, it's probably best
//!    to limit pre-background operations to the bare minimum, such as parsing arguments (but
//!    not acting on them, except perhaps to determine if backgrounding has been requested, etc).
//! 
int enter_background(int(0..1) should_we, string logfile, void|int(0..1) quiet)
{
  // no need to attempt to enter the background if we're already there.
  if(in_child) return 0;

  if(!should_we)
    return 0;

  if(!quiet)
  {
    write("Entering Daemon mode...\n");
    write("Directing output to %s.\n", logfile);
  }
  
  // first, we attempt to open the log file; if we can't, bail out.
  object lf;
  mixed e = catch(lf = Stdio.File(logfile, "crwa"));
  if(e) 
  {
    werror("Unable to open log file: " + Error.mkerror(e)->message());
    werror("Exiting.\n");
    exit(1);
  }
    
#if constant(fork)
  object c = fork();
  if(!c)
  {
    in_child = 1;
    child_pid = pidlet();
  }
  else
  {
    child_pid = c;
  }
#elseif constant(System.FreeConsole)
  child_pid = Process.spawn_pike(bootargs + argv + ({"--tools-application-backgrounder=go-background", "--tools-application-backgrounder-logfile=" + logfile}), ([]));
  if(child_pid->status == 0) // good, we're running
  {
    in_child = 0;
  }
#else
  return 0;
#endif /* constant(fork) */
  
  if(in_child)
  {
    // this is the code we run in the child.
    close_stdio(logfile);
    return 0;
  }
  else
  {
    if(!quiet)
      werror("Daemon pid: %O\n", child_pid->pid());
    return 1;
  }  
}

protected void close_stdio(string logfile)
{
  Stdio.stdin.close();
  Stdio.stdin.open("/dev/null", "crwa");
  Stdio.stdout.close();
  Stdio.stdout.open(logfile, "crwa");
  Stdio.stderr.close();
  Stdio.stderr.open(logfile, "crwa");
}

//! returns true if we're actually the child process.
int in_background()
{
  return in_child;
}

//! get the process object for the child process, if any.
//! 
//! @returns
//!   the process id of the child process.
//!
//! @note
//!   when running in environments that don't have @[fork], such as Windows, 
//!   the child process id will be the current process. Therefore, this method 
//!   should only be used to get the process id for informational purposes.
int get_child_pid()
{
  return child_pid->pid();
}

