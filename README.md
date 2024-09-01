# rem
`rem` is a remote executable manager. The server runs an executable while the client controls the state using commands. The executable will continue to run even if the client has disconnected, and any number of clients can be connected and send commands at any instance.

### usage

A payload consists of a byte representing the command, followed by the data. Currently, the client can only send signals to the running process, and the server will exit if the child exits.

On the server:
``` console
$ rem /usr/bin/sleep infinity
info: executing command with pid: 1495034
```

On the client:
``` console
$ nc localhost 8080
```

Then, send `k9\n` from the client to the server, which will then send `SIGINT` to the executed process. Only portable signal numbers (shown [here](https://en.wikipedia.org/wiki/Signal_%28IPC%29#POSIX_signals)) can be sent.