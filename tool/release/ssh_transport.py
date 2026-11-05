"""Byte-transparent TCP transport for the pinned Beijing SSH receiver.

The previous release stalled on full-sized TCP segments across this route.
Keep the tested 1200-byte MSS while SSH still owns authentication, encryption,
host-key verification and the receiver's restricted command.
"""
import errno,socket,sys,threading
host='39.105.82.189'
with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as upstream:
    try:
        upstream.setsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG,1200)
    except OSError as e:
        if e.errno != errno.EINVAL: raise
    upstream.settimeout(20);upstream.connect((host,22))
    upstream.setsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG,1200)
    upstream.settimeout(None)
    def send():
        try:
            while data:=sys.stdin.buffer.read1(65536):
                upstream.sendall(data)
            upstream.shutdown(socket.SHUT_WR)
        except OSError:
            pass
    threading.Thread(target=send,daemon=True).start()
    while data:=upstream.recv(65536):
        sys.stdout.buffer.write(data);sys.stdout.buffer.flush()
