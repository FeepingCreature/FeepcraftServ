module main;

import std.socket, std.boehm, std.thread;

import base, simplex, player, server, world;

void main() {
  initBoehm();
  set-handler (Error er) { writeln "!! $er"; invoke-exit "return"; }
  define-exit "return" return;
  auto ls = new Socket;
  ls.reuse true;
  ls.bind(new TcpAddress("0.0.0.0", short:25565));
  ls.listen();
  writeln "Listening. ";
  Player[] players;
  auto playerLock = new Mutex;
  auto tp = new ThreadPool 1;
  auto server = new Server;
  tp.addTask delegate void() {
    while true {
      server.waitRead(1);
      server.readPackets();
    }
  };
  auto dg1 = delegate byte(vec3i ipos) {
    float noise3x(vec3f v) {
      return noise3 vec3f(v.x + noise3(v), v.y + noise3(-v), v.z);
    }
    auto pos = vec3f(ipos);
    pos.x /= 2;
    pos.y /= 2;
    pos.z /= 2;
    auto val =
    - noise3x vec3f(pos.x / 64f, pos.y / 64f, pos.z / 64f) * 32
    + noise3x vec3f(pos.x / 32f, pos.y / 32f, pos.z / 32f) * 16
    + noise3x vec3f(pos.x / 16f, pos.y / 16f, pos.z / 16f) * 8
    // + noise3x vec3f(pos.x /  8f, pos.y /  8f, pos.z /  8f) * 4
    ;
    val += ipos.y - 60;
    if val < 0 return byte:3;
    return byte:0;
  };
  auto dg2 = delegate byte(vec3i pos) {
    auto waterline = 56;
    auto prelim = dg1(pos);
    if prelim == 0 {
      if pos.y < waterline return byte:8;
    }
    if prelim == 3 {
      auto above = dg1(pos + vec3i.Y);
      if above == 0 {
        if pos.y == waterline - 1 return byte:12;
        if pos.y > waterline - 1 return byte:2;
      }
    }
    return prelim;
  };
  auto world = new World(dg2);
  while true {
    auto sock = ls.accept();
    using autoLock server.serverMutex server.connecting ~= IPlayer: new Player (server, world, sock);
  }
}
