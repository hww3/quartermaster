

int main(int argc, array(string) argv) {
  string socket_path;
  
  if(argc != 2) {
    werror("Usage: qm_command /path/to/socket\n");
    return 1;
  }
  
  socket_path = argv[1];
  
  Stdio.File socket = Stdio.File();
  write("Connecting to QuarterMaster control socket %s.\n", socket_path);
   
  if(!socket->connect_unix(socket_path)) {
    werror("Unable to open socket.\n");
    return 2;
  }

  write("Connected.\n");
  
  socket->write("{\"cmd\": \"status\"}");
  
  do {
    write(socket->read(1024, 1));
  } while(1);
  
  return 0;
}