#!/usr/bin/env python3
"""Loopback-only HTTP fixture for tool/verify_native_services.dart (not an AI)."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import math
import struct
import wave

buffer = io.BytesIO()
with wave.open(buffer, 'wb') as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(24000)
    samples = [int(4000 * math.sin(i * 2 * math.pi * 440 / 24000)) for i in range(36000)]
    audio.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
WAV = buffer.getvalue()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.headers.get('Authorization') != 'Bearer release-test-only':
            self.send_error(401)
            return
        if self.path == '/v1/chat/completions':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
            self.end_headers()
            for part in ['原生安装版连接成功。', 'HTTP 流式回复已到达。']:
                self.wfile.write(('data: ' + json.dumps({'choices': [{'delta': {'content': part}}]}, ensure_ascii=False) + '\n\n').encode())
                self.wfile.flush()
            self.wfile.write(b'data: [DONE]\n\n')
        elif self.path == '/v1/audio/speech' and payload['response_format'] == 'wav':
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Content-Length', str(len(WAV)))
            self.end_headers()
            self.wfile.write(WAV)
        else:
            self.send_error(404)

if __name__ == '__main__':
    print('Local fixture listening on 127.0.0.1:18877; no external requests.', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 18877), Handler).serve_forever()
