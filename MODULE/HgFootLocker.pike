inherit .FootLocker;

ADT.Queue commit_queue = ADT.Queue();
mixed commit_task = 0;
multiset remote_commands = (<"push", "pull", "incoming", "outgoing">);
int commit_running = 0;
int pull_needed = 0;


void verify_local_repository() {
werror("verifying repository for %s\n", dir);
  mapping res = run_hg_command("status");
  
  werror("hg status returned status %d, stdout: %O, stderr: %O\n", res->exitcode, res->stdout, res->stderr);
  
  if(res->exitcode == 255) { // no repository present
    // ok, first step is to initialize an empty repository here
    res = run_hg_command("init");
    if(res->exitcode) {
      // if the init failed for some reason, return us to a repository-less situation.
      Stdio.recursive_rm(get_dir("/.hg"));
      explain_hg_error(res);
    }
	
	    res = run_hg_command("pull", " --rebase -t internal:merge-local " + configuration->source);
	    if(res->exitcode) {
	      // if the pull failed for some reason, return us to a repository-less situation.
	      // we may possibly be left with a partial pull, but at least there will be no data loss.
	      Stdio.recursive_rm(get_dir("/.hg"));
	      explain_hg_error(res);
	    }
	    res = run_hg_command("update");
	    if(res->exitcode == 1) {
	      res = run_hg_command("merge", "-t internal:merge-local");
	    }
	    else if(res->exitcode == 0) { // success
	    } else {
	      // if the update failed for some reason, return us to a repository-less situation.
	      // we may possibly be left with a partial pull, but at least there will be no data loss.
	      Stdio.recursive_rm(get_dir("/.hg"));
	      explain_hg_error(res);
	    }
	
  } else if(res->exitcode == 0) { // repository present
  } else {
    throw(Error.Generic("unable to determine state of footlocker repository: " + res->stderr + "\n"));
  }
 
/* we don't actually need to do this, as the watcher will cause a refresh of any added files, 
   which will trigger a pull if there are any incoming changes. */ 

werror("repository successfully verified for %s\n", dir);
}

string get_dir(string subdir) {
  return Stdio.append_path(dir, subdir);
}

void explain_hg_error(mapping res) {
  string exp = sprintf("We ran the command %s, and it returned exitcode %d, stdout: %O, stderr: %O\n", 
                        res->command, res->exitcode, res->stdout, res->stderr);
  werror(exp);
  add_history(HISTORY_TYPE_ERROR, exp);
  throw(Error.Generic(exp));
}

mapping run_hg_command(string command, string|void args) {
   string cmdstr = "hg " + command;
   if(remote_commands[command]) cmdstr += " --ssh \"ssh -i '" + configuration->private_key + "'\""; 
   if(args)
     cmdstr += (" " + args);
   werror("-> running %s\n", cmdstr);
   return Process.run(cmdstr, (["cwd": dir])) + (["command": cmdstr]);
}

void add_new_file(string path, int|void advisory) {
  string fpath = path;
//werror("add_new_file(%O, %O)\n", path, advisory);
  if(path == dir) return;
  path = normalize_path(path);
  mapping res = run_hg_command("add", "'" + path + "'");
 // werror("res: %O\n", res->stderr);
  // TODO 
  if(!Stdio.is_dir(fpath) && !has_suffix(res->stderr, " already tracked!\n")) {
    werror("new file %O\n", path);
    need_commit(path);
  }
}

void remove_file(string path) {
  if(path == dir) return;
  path = normalize_path(path);
  run_hg_command("rm", path);
  need_commit(path);
}

void save_changed_file(string path, Stdio.Stat st) {
  if(path == dir) return;
  string fpath = path;
  path = normalize_path(path);
  if(Stdio.is_dir(fpath)) return;
  
  need_commit(path);
}

string normalize_path(string path) {
   return path[sizeof(dir)+1..];
}

// add path to list of files to committed and schedule a commit task.
void need_commit(string path) {
  set_processing_state(PROCESSING_STATE_PENDING);
  commit_queue->put(path);
  if(commit_task == 0) {
    werror("scheduling commit task\n");
    commit_task = call_out(run_commit, commit_coalesce_period);
  }
}

void run_commit() {
  // if a commit was scheduled but the current one is still running, abort and try again shortly.
  werror("run_commit\n");
  if(commit_running) { 
  werror("  was already running. trying again later.\n");
    remove_call_out(run_commit); 
    commit_task = call_out(run_commit, 1); 
    return 0; 
  }
  
  workers->run_async(do_run_commit);
}

void do_run_commit() {
  commit_running = 1;
  commit_task = 0;
  stop_processing_events();
  ADT.Queue entries = commit_queue;
  array ents = Array.uniq(values(entries));
//  werror("commit queue: %O\n", ents);
  commit_queue = ADT.Queue();
  mixed e;

  mapping st = run_hg_command("status", "-m -a -r -d -n");
  array files_affected = (st->stdout/"\n");
  array files_to_ignore = ents - files_affected;
  ents = ents & files_affected;
//  werror("ignoring %O\n", files_to_ignore);
  if(sizeof(ents)) {
    set_processing_state(PROCESSING_STATE_RECORDING);

    mapping resp = run_hg_command("commit", "-m 'QuarterMaster generated commit from " + gethostname() + ".\n\nFiles modified:\n\n" + 
                      sprintf("%{%s\n%}", ents) + "' " + sprintf("%{'%s' %}", ents));
//    werror("resp: %O\n", resp);
    add_history(HISTORY_TYPE_INFO, "Recorded changes to "  + sizeof(ents) + " files.\n" + sprintf("%{%s\n%}", ents));
    
  set_processing_state(PROCESSING_STATE_IDLE);

  if(resp->exitcode == 0) 
      e = catch(pull_n_push_changes());
	  } else if (pull_needed) {
		  pull_needed = 0;
		  e = catch(pull_n_push_changes());
	  } 
	  
  start_processing_events();
  commit_running = 0;
  if(e) throw(e);
}


void pull_n_push_changes() {
  stop_processing_events();
    set_processing_state(PROCESSING_STATE_RECEIVING);
  mapping r;
//  mapping r = run_hg_command("incoming",  configuration->source);
//  if(r->exitcode == 0) {
    r = pull_changes();
    if(r->exitcode != 0) {
      catch(explain_hg_error(r));
    }
    r = update_changes();
    if(r->exitcode != 0) {
      catch(explain_hg_error(r));
      set_repository_state(REPOSITORY_STATE_ERROR);
    }
//  } else if(r->exit_code > 1) {
//     catch(explain_hg_error(r));
//  } else {

  set_processing_state(PROCESSING_STATE_SENDING);
  
  r = push_changes();
//  }
  
  // TODO we need to have better error handling here.
  start_processing_events();
    set_processing_state(PROCESSING_STATE_IDLE);

  if(r->exitcode == 0) {
     add_history(HISTORY_TYPE_INFO, "Sent changes.");
     changes_pushed();
  }
  if(!(<0,1>)[r->exitcode]) // zero is success, one is nothing to push. 
  {
    explain_hg_error(r);
    set_repository_state(REPOSITORY_STATE_ERROR);
  } else {
    set_repository_state(REPOSITORY_STATE_CLEAN);
  }
}

void pull_incoming_changes() {
  if(commit_task != 0 || commit_running == 1) // a commit is either running or will be soon, so we should defer. that way we don't lose local, uncommitted changes
  {
     pull_needed = 1;
	 return;	 
  }
	
	workers->run_async(do_pull_incoming_changes);
}

void do_pull_incoming_changes() {
	
  stop_processing_events();
  set_processing_state(PROCESSING_STATE_RECEIVING);
  mapping r;

    r = pull_changes();
    if(r->exitcode != 0) {
      catch(explain_hg_error(r));
    }
    r = update_changes();
    if(r->exitcode == 0) {
        set_repository_state(REPOSITORY_STATE_CLEAN);
        // TODO include source and files affected.
        add_history(HISTORY_TYPE_INFO, "Received incoming changes.");
    }
    if(r->exitcode != 0) {
      set_repository_state(REPOSITORY_STATE_ERROR);
      catch(explain_hg_error(r));
    }

  // TODO we need to have better error handling here.
  set_processing_state(PROCESSING_STATE_IDLE);
  start_processing_events();
}

mapping push_changes() {
  mapping res = run_hg_command("push", configuration->source);
  return res;
}

mapping update_changes() {
  mapping res = run_hg_command("update", "--check");
  if(res->exitcode == 1) {
      res = run_hg_command("merge", "-t internal:merge-local");
  }

  return res;
}

mapping pull_changes() {
   mapping res = run_hg_command("pull", "--rebase -t internal:merge-local " + configuration->source);
   return res;
}
