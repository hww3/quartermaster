// control socket


protected string socket_path;

protected Stdio.Port socket; // pty

protected mapping conns = ([]);
protected mapping conn_data = ([]);

protected object delegate;

int main() {
  return -1;
}

void create(string path, object _delegate) {
  socket_path = path;
  delegate = _delegate;
  if(!create_socket()) werror("failed to open %s\n", socket_path);
}

int create_socket() {
  socket = Stdio.Port();
  socket->set_id(socket_path);
  if(Stdio.exist(socket_path)) {
    if(!rm(socket_path))
      werror("Unable to clear control socket %s, remote control will likely not work.\n", socket_path);
  }
  
  mixed e = catch {
    socket->bind_unix(socket_path, accept_connection);
  };
  if(e) werror("Error creating control socket: %O\n", Error.mkerror(e)->message());
  if(e || !socket) return 0;                                
  else return 1;            
}                           

void accept_connection(mixed id) {
werror("accept_connection(%O)\n", id);
  Stdio.File fd = socket->accept();
  
  if(!fd) {
    werror("accept returned no connection!\n");
    return;
  }
  
  fd->set_nonblocking();                                            
  fd->set_read_callback(socket_read_cb);                                  
  fd->set_write_callback(socket_write_cb);                                
  fd->set_close_callback(socket_close_cb);
  
  object uuid = Standards.UUID.make_version4();
  fd->set_id(uuid);
  conns[uuid] = fd;
  conn_data[uuid] = ([ "read_buffer": "", "write_buffer": "", "brace_count": 0, "last_pos": 0]);
  
  werror("Control socket connection %O opened.\n", (string)uuid);
}

void close_socket(Standards.UUID.UUID uuid) {
  werror("Control socket connection %O closed.\n", (string)uuid);
  Stdio.File fd = conns[uuid];
  if(fd) fd->close();
  m_delete(conns, uuid);
  m_delete(conn_data, uuid);
}
               
int i,j;                    
                            
int socket_read_cb(mixed id, string data) {
  if(!sizeof(data)) return 0;

  Stdio.File fd = conns[id];
  mapping d = conn_data[id];
  
  if(!fd || !d) {
    werror("Socket registration mismatch for connection id=%O: fd=%O, data=%O\n", id, fd, data);
    return 0;
  }
  
  d->read_buffer += data;
  
  socket_got_data(id, fd, d);
  return 0;
} 

void socket_got_data(Standards.UUID.UUID uuid, Stdio.File fd, mapping data) {
  streaming_decode(data, command_received, uuid);
}

void status_changed(string flname, mapping status) {
  foreach(conns; Standards.UUID.UUID uuid; Stdio.File fd) {
    send_response((["event": "status_changed", "footlocker": flname, "data": status]), uuid);
  }
}

mapping command_received(mapping cmd, Standards.UUID.UUID uuid) {
   werror("command received: %O\n", cmd);
   if(cmd->cmd && delegate[cmd->cmd])
     send_response(delegate[cmd->cmd](cmd) + (["event": cmd->cmd]), uuid);
   else send_response((["error": "invalid_command"]), uuid);
}

void send_response(mapping result, Standards.UUID.UUID id) {
  Stdio.File fd = conns[id];
  mapping d = conn_data[id];
  
  if(!fd || !d) {
    werror("Socket registration mismatch for connection id=%O: fd=%O, data=%O\n", id, fd, d);
    return 0;
  }
  
  string json = Standards.JSON.encode(result + (["timestamp": time()]));
  
  werror("sending %s to socket %O\n", json, (string)id);
  socket_write(id, fd, json);
}

// attempt to detect full json objects in a buffer and end them to an event callback.
// TODO we are naive about counting braces. We need to skip those that appear within string literals.
void streaming_decode(mapping data, function event, mixed ... args) {
  int len = sizeof(data->read_buffer);
  if(!len) return;
  
  for(; data->last_pos < len; data->last_pos++) {
    if(sizeof(data->read_buffer)<=data->last_pos) continue; 
    if(data->read_buffer[data->last_pos] == '{') {
      data->brace_count++;        
    } else if(data->read_buffer[data->last_pos] == '}') {
      data->brace_count--;        
      if(data->brace_count == 0) {
        werror("sending json for decode: \n\n" + data->read_buffer[0..data->last_pos] + "\n\n");
        mixed json = Standards.JSON.decode(data->read_buffer[0..data->last_pos]);
        if(len > data->last_po+1) {
          data->read_buffer = data->read_buffer[data->last_pos+1..];
          werror("decode buffer is now: %O\n", data->read_buffer);  
          len = sizeof(data->read_buffer);
        }                   
        else data->read_buffer = "", len=0;
        data->last_pos = -1;      
        event(json, @args);        
      } else if(data->brace_count < 0) {
          throw(Error.Generic("brace_count reached " + data->brace_count + " in decode_buffer " + data->read_buffer));
      }                     
    }                       
  }                         
}       


void socket_write(Standards.UUID.UUID uuid, Stdio.File fd, string data) {
   mapping d = conn_data[uuid];
   
   if(sizeof(d->write_buffer)) {
     data = d->write_buffer + data;
     d->write_buffer = "";
   }
   
  int x = fd->write(data);
   
  if(x < sizeof(data)) {
    d->write_buffer = data[x..];
  }
}

int socket_write_cb(mixed id) {
  Stdio.File fd = conns[id];
  mapping d = conn_data[id];
  
  if(!fd || !d) {
    werror("Socket registration mismatch for connection id=%O: fd=%O, data=%O\n", id, fd, d);
    return 0;
  }
  
  if(!sizeof(d->write_buffer)) return 0;

  int x = fd->write(d->write_buffer, 1);
  if(x == sizeof(d->write_buffer)) 
    d->write_buffer = "";        
  else                      
    d->write_buffer = d->write_buffer[x..];
  return x;                 
}
                            
int socket_close_cb(mixed id) {   
  werror("Control socket connection %O closed.\n", (string)id);
  m_delete(conns, id);
  m_delete(conn_data, id);
  
  return 0;                  
}     

