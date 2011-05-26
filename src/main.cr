module main;

import std.socket, std.stream, std.boehm, std.zlib, std.time, std.thread;

import bigendian;

class Item {
  short id;
  void init(short id) this.id = id;
}

alias abs-vec3i = vec3i; // absolute world pos

class Drop {
  Item item;
  int eid;
  abs-vec3i pos;
  void init(Item it, int eid, abs-vec3i pos) this.(item, eid, pos) = (it, eid, pos);
}

class World {
  byte delegate(vec3i) genDg;
  class Chunk {
    vec3i pos;
    byte[] data;
    int getIdx(vec3i local) {
      return local.y + 16 * (local.z + local.x * 64);
    }
  }
  Chunk[] chunks;
  Drop[] drops;
  void removeDrop(Drop d) {
    bool found;
    while (int i, Drop drop) <- zip(0..-1, drops) && !found
      if (int:drop == int:d) {
        found = true;
        drops[i] = drops.popEnd;
      }
    if !found raise-error new Error "Can't remove: no such drop! ";
  }
  void init(byte delegate(vec3i) dg) {
    genDg = dg;
  }
  // must be divisible by <16, 64, 16>
  Chunk lookupChunkAt(vec3i pos) {
    for auto chunk <- chunks
      if chunk.pos == pos
        return chunk;
    auto ch = new Chunk;
    ch.pos = pos;
    byte[auto~] data;
    for int x <- 0..16
      for int z <- 0..16
        for int y <- 0..64
          data ~= genDg(vec3i(x, y, z) + pos);
    ch.data = data[];
    chunks ~= ch;
    return ch;
  }
  void changeBlock(vec3i pos, byte newVal) {
    auto chunkPos = vec3i(pos.(x >> 4, y >> 6, z >> 4));
    auto chunkWorldPos = vec3i(chunkPos.(x << 4, y << 6, z << 4));
    auto chunk = lookupChunkAt chunkWorldPos;
    auto delta = pos - chunkWorldPos;
    chunk.data[chunk.getIdx(delta)] = newVal;
  }
}

int eidCount = 1;

interface IPlayer {
  string getName();
  Socket getSocket();
  void sendChatMessage(string);
  void readPacket();
  void removeSelf(bool quietly);
  void removeEntity(int eid);
}

template removeClassFrom(T) <<EOF
  void removeClassFrom(T t) {
    alias ar = *t[0];
    int i;
    while i < ar.length {
      if int:ar[i] == int:t[1] {
        ar[i] = ar.popEnd();
        return;
      }
    }
    raise-error new Error "No $(t[1]) in $(t[0])!";
  }
EOF

class Server {
  IPlayer[] players;
  IPlayer[] connecting;
  Mutex serverMutex;
  void init() {
    serverMutex = new Mutex;
  }
  void broadcast(string s, string except = "") {
    for auto player <- players {
      if player.getName() != except
        player.sendChatMessage s;
    }
  }
  IPlayer[] selectOthers(IPlayer except) {
    IPlayer[auto~] res;
    for auto player <- players
      if int:player != int:except
        res ~= player;
    return res[];
  }
  void addPlayer(IPlayer pl) using autoLock serverMutex {
    players ~= pl;
  }
  void removePlayer(IPlayer removeMe) using autoLock serverMutex {
    removeClassFrom(&players, removeMe);
  }
  void removeConnectingPlayer(IPlayer removeMe) using autoLock serverMutex {
    removeClassFrom(&connecting, removeMe);
  }
  void readPackets() {
    IPlayer[] localPlayers;
    onSuccess localPlayers.free;
    using autoLock serverMutex localPlayers = players ~ connecting;
    for auto player <- localPlayers {
      Error err;
      set-handler (Error _err) { writeln "While processing $(player.getName()): $_err"; err = _err; invoke-exit "remove"; }
      define-exit "remove" {
        player.removeSelf(quietly=>true);
        broadcast " * $(player.getName()) has disconnected: $err";
        return;
      }
      player.readPacket();
    }
  }
  void waitRead(float timeout) {
    using SelectSet ss {
      IPlayer[] localPlayers;
      using autoLock serverMutex localPlayers = players;
      for auto player <- localPlayers {
        add(player.getSocket(), read => true);
      }
      select timeout => timeout;
    }
  }
}

class Player : IPlayer {
  Server server;
  World world;
  Socket sock;
  string name;
  int eid;
  BigEndianDataStream ds;
  double x, y, z, stance;
  float yaw, pitch;
  bool onGround;
  double lastPing;
  vec2i[] loadedChunks;
  vec2i lastPlayerChunkPos;
  vec3i lastPlayerBlockPos;
  Player[] otherPlayers() return [for pl <- server.selectOthers this: Player: pl].eval;
  Socket getSocket() return sock;
  string getName() return name;
  void init(Server server, World world, Socket sock) {
    this.server = server;
    this.world = world;
    (x, y, z) = (8.0, 64.0, 8.0);
    stance = y + 2;
    this.sock = sock;
    ds = new BigEndianDataStream(readDg &sock.recv #.(&step, &ivalid));
    lastPing = sec();
  }
  byte yawByte() { int iyaw = int:(yaw * 256f / 360); return *byte*: &iyaw; }
  byte pitchByte() { int ipitch = int:(pitch * 256f / 360); return *byte*: &ipitch; }
  void sendPacket(byte kind, byte[] data = byte[]:(null x 2)) {
    sock.send void[]:(&kind#[0..1]);
    if data.length sock.send void[]:data;
  }
  void sendLoginResponse(int protver, string name, long seed, byte dimension) {
    byte[auto~] data;
    eid = eidCount ++;
    data ~= toField eid;
    data ~= name.encodeUCS2();
    data ~= toField seed;
    data ~= dimension;
    sendPacket(1, data[]);
    data.free;
  }
  void sendSpawnLocation(int x, y, z) {
    byte[auto~] data;
    data ~= toField x;
    data ~= toField y;
    data ~= toField z;
    sendPacket(6, data[]);
    data.free;
  }
  void sendPreChunk(int x, z, bool load) {
    byte[auto~] data;
    data ~= toField x;
    data ~= toField z;
    data ~= *byte*:&load;
    sendPacket(0x32, data[]);
    data.free;
  }
  void sendEmptyInventory() {
    byte[auto~] data;
    data ~= 0; // inv
    data ~= toField short:45;
    for 0..45 {
      data ~= toField short:-1;
    }
    sendPacket(0x68, data[]);
    data.free;
    data ~= -1; // init
    data ~= toField short:-1; // init
    data ~= toField short:-1;
    data ~= byte:0;
    data ~= toField short:0;
    sendPacket(0x67, data[]);
    data.free;
  }
  void sendMapChunk(vec3i intPos, vec3i intSize) {
    byte[auto~] data;
    data ~= toField intPos.x;
    data ~= toField short:intPos.y;
    data ~= toField intPos.z;
    data ~= *byte*:&intSize.x;
    data ~= *byte*:&intSize.y;
    data ~= *byte*:&intSize.z;
    byte[auto~] types, metadata, light, skylight;
    auto ch = world.lookupChunkAt intPos;
    types ~= ch.data;
    for int x <- 0..intSize.x+1
      for int z <- 0..intSize.z+1 {
        for (int y = 0; y <= intSize.y; y += 2) {
          metadata ~= 0;
          light ~= 0xff;
          skylight ~= 0xff;
        }
      }
    byte[auto~] all;
    all ~= types[];    types.free;
    all ~= metadata[]; metadata.free;
    all ~= light[];    light.free;
    all ~= skylight[]; skylight.free;
    auto def = new Deflate;
    onSuccess def.fini;
    auto compressed = def.deflate all[];
    // writeln "uncompressed size: $(all.length)";
    all.free;
    // writeln "compressed size: $(compressed.length)";
    data ~= toField compressed.length;
    data ~= compressed;
    compressed.free;
    sendPacket(0x33, data[]);
    data.free;
  }
  void sendNewChunk(vec2i v) {
    sendPreChunk(v, true);
    vec3i pos = vec3i(v.(x << 4, 0, y << 4));
    sendMapChunk(pos, vec3i(15, 63, 15));
    pos.y += 64;
    sendMapChunk(pos, vec3i(15, 63, 15));
  }
  void unloadChunk(vec2i v) {
    sendPreChunk(v, false);
  }
  void pickupItemAnim(Drop d) {
    byte[auto~] data;
    data ~= toField d.eid;
    data ~= toField eid;
    sendPacket(0x16, data[]);
    data.free;
  }
  void playerMovementChecks() {
    auto playerBlockPos = vec3i(int:x, int:y, int:z);
    if playerBlockPos == lastPlayerBlockPos && loadedChunks.length
      return;
    lastPlayerBlockPos = playerBlockPos;
    
    int i;
    auto playerAbsPos = vec3i(int:(x * 32), int:(y * 32), int:(z * 32));
    while i < world.drops.length {
      auto d = world.drops[i];
      if |d.pos - playerAbsPos| < 32 {
        pickupItemAnim d;
        world.removeDrop d;
        for auto player <- server.players
          player.removeEntity d.eid;
      }
      i++;
    }
    
    auto playerChunkPos = vec2i(int:x >> 4, int:z >> 4);
    if playerChunkPos == lastPlayerChunkPos && loadedChunks.length
      return;
    lastPlayerChunkPos = playerChunkPos;
    
    vec2i[auto~] newChunks;
    // build newChunks
    // also, send all chunks that are in newChunks but not in loadedChunks,
    for int z <- -3..4
      for int x <- -3..4 {
        auto chnk = vec2i(x, z) + playerChunkPos;
        bool found;
        while auto ch <- loadedChunks && !found
          if ch == chnk found = true;
        if !found sendNewChunk chnk;
        newChunks ~= chnk;
      }
    // invalidate all that are in loadedChunks but not newChunks,
    for auto ch <- loadedChunks {
      bool found;
      while auto ch2 <- newChunks && !found
        if ch == ch2 found = true;
      if !found unloadChunk ch;
    }
    // replace loadedChunks with newChunks.
    if loadedChunks.length
      loadedChunks.free;
    loadedChunks = newChunks[];
  }
  void sendPlayerPosLook() {
    byte[auto~] data;
    data ~= toField x;
    data ~= toField double:(y + 1.65);
    data ~= toField y;
    data ~= toField z;
    data ~= toField yaw;
    data ~= toField pitch;
    data ~= *byte*:&onGround;
    sendPacket(0x0d, data[]);
    data.free;
  }
  void sendChatMessage(string msg) {
    byte[auto~] data;
    data ~= msg.encodeUCS2();
    sendPacket(0x03, data[]);
    data.free;
  }
  void readHandshake() {
    auto str = ds.readUCS2(ds.readShort() * 2);
    sendPacket(2, encodeUCS2("-"));
  }
  void spawnEntityFor(Player pl) {
    byte[auto~] data;
    using pl {
      data ~= toField eid;
      data ~= name.encodeUCS2();
      data ~= toField int:(x*32);
      data ~= toField int:(y*32);
      data ~= toField int:(z*32);
      data ~= yawByte(); // rotation
      data ~= pitchByte(); // pitch
      data ~= toField short:0; // current item
    }
    sendPacket(0x14, data[]);
    data.free;
  }
  void readLoginRequest() {
    auto protver = ds.readInt();
    writeln "Protocol version: $protver";
    name = ds.readUCS2(ds.readShort() * 2);
    writeln "Logging in: $name";
    ds.readLong(); // map seed
    ds.readByte(); // dimension
    sendLoginResponse(11, string:(null x 2), 0, 0);
    sendSpawnLocation(0, 64, 0);
    sendEmptyInventory();
    playerMovementChecks();
    sendPlayerPosLook();
    sendChatMessage "<server> Hi! I am feepserv!";
    sendChatMessage "<server> I am pretty crashy, so don't";
    sendChatMessage "<server> get worried when you disconnect! ";
    server.removeConnectingPlayer(this);
    server.addPlayer(this);
    server.broadcast("[server] $name has joined! ");
    // spawn other players for me
    for auto other <- otherPlayers() {
      other.spawnEntityFor this;
      spawnEntityFor other;
    }
  }
  void readChatMessage() {
    auto msg = ds.readUCS2(ds.readShort() * 2);
    auto line = "<$name> $msg";
    writeln line;
    server.broadcast line;
  }
  void updatePosLookFor(Player pl) {
    ubyte[auto~] data;
    using pl {
      data ~= toField eid;
      data ~= toField int:(x * 32);
      data ~= toField int:(y * 32);
      data ~= toField int:(z * 32);
      data ~= yawByte();
      data ~= pitchByte();
    }
    sendPacket(0x22, data[]);
    data.free;
  }
  void updatePosLook() {
    playerMovementChecks();
    for auto other <- otherPlayers() {
      other.updatePosLookFor this;
    }
  }
  void readPlayerPos() {
    x = ds.readDouble(); y = ds.readDouble(); stance = ds.readDouble(); z = ds.readDouble();
    onGround = bool:ds.readByte();
    updatePosLook();
    // writeln "pos <$x, $y, $z> stance $stance onGround $onGround";
    // sendPlayerPosLook;
  }
  void readPlayerLook() {
    yaw = ds.readFloat(); pitch = ds.readFloat();
    onGround = bool:ds.readByte();
    updatePosLook();
    // writeln "yaw $yaw pitch $pitch onGround $onGround";
    // sendPlayerPosLook;
  }
  void readPlayerPosLook() {
    x = ds.readDouble(); y = ds.readDouble(); stance = ds.readDouble(); z = ds.readDouble();
    yaw = ds.readFloat(); pitch = ds.readFloat();
    onGround = bool:ds.readByte();
    updatePosLook();
    // writeln "pos <$x, $y, $z> stance $stance yaw $yaw pitch $pitch onGround $onGround";
    // sendPlayerPosLook;
  }
  void readPlayerOnGround() {
    onGround = bool:ds.readByte();
    // writeln "player $([\"airborne\", \"on ground\"][onGround])";
  }
  void readPlayerEntityAction() {
    auto eid = ds.readInt();
    auto action = ds.readByte();
    writeln ["?", "Crouch", "Uncrouch", "Leave bed"][action];
  }
  void readPlayerUse() {
    auto eid = ds.readInt();
    auto target = ds.readInt();
    bool leftClick = bool:ds.readByte();
    server.broadcast "Can't handle this yet: $eid $([\"right\", \"left\"][leftClick]) clicks on $target";
  }
  void readPlayerAnimation() {
    auto eid = ds.readInt();
    auto animation = ds.readByte();
    if (animation < 4) writeln ["None", "Swing Arm", "Damage", "Leave bed"][animation];
    else writeln "animation $$int:animation";
    sendPacket(0);
  }
  void updateBlock(vec3i worldPos, byte newval) {
    auto chunkPos = vec3i(worldPos.(x >> 4, y >> 6, z >> 4));
    bool found;
    while auto ch <- loadedChunks && !found
      if (ch == chunkPos.xz)
        found = true;
    if !found return; // not visible
    byte[auto~] data;
    data ~= toField worldPos.x;
    data ~= *byte*:&worldPos.y;
    data ~= toField worldPos.z;
    data ~= newval;
    data ~= byte:0;
    sendPacket(0x35, data[]);
    data.free;
  }
  void animatePlayer(Player pl, byte anim) {
    byte[auto~] data;
    data ~= toField pl.eid;
    data ~= anim;
    sendPacket(0x12, data[]);
    data.free;
  }
  void spawnItem(Drop dr) using dr {
    byte[auto~] data;
    data ~= toField eid;
    data ~= toField item.id;
    data ~= byte:1;
    data ~= toField short:0;
    data ~= toField int:pos.x;
    data ~= toField int:pos.y;
    data ~= toField int:pos.z;
    data ~= byte:0; // rotation
    data ~= byte:0; // pitch
    data ~= byte:0; // roll
    writeln "$name: spawn item at $(pos) ($$short:item.id)";
    sendPacket(0x15, data[]);
    data.free;
  }
  void readPlayerDigging() {
    byte status = ds.readByte();
    int x = ds.readInt(); byte y = ds.readByte(); int z = ds.readInt();
    byte face = ds.readByte();
    auto pos = vec3i(x, y, z);
    if (status == 0) {
      for auto player <- otherPlayers() player.animatePlayer(this, 1);
    }
    if (status == 2) { // finished digging
      for auto player <- otherPlayers() player.animatePlayer(this, 0);
      world.changeBlock(pos, 0);
      for auto player <- [for pl <- server.players: Player: pl] {
        auto dr = new Drop(new Item 3, eidCount ++, vec3i(vec3f(pos) + 0.5 #.(int:(x * 32), int:(y * 32), int:(z * 32))));
        player.spawnItem(dr);
        world.drops ~= dr;
        player.updateBlock(pos, 0);
      }
    }
    writeln "Player digging at $x, $$int:y, $z (face $$int:face, status $$int:status)";
  }
  void readPlayerHoldingChange() {
    short slotId = ds.readShort();
    writeln "Player switched to slot $$int:slotId";
  }
  void sendPing() { lastPing = sec(); sendPacket(0); }
  void readPing() { sendPing; }
  void considerPing() {
    if (float:(sec() - lastPing) > 1.0) sendPing;
  }
  void removeEntity(int eid) {
    byte[auto~] data;
    data ~= toField eid;
    sendPacket(0x1d, data[]);
    data.free;
  }
  void removeSelf(bool quietly) {
    for auto other <- otherPlayers() {
      other.removeEntity eid;
    }
    server.removePlayer this;
    if !quietly
      server.broadcast("[server] $name has quit. ");
  }
  void readPlayerOpenWindow() {
    auto
      id = ds.readByte(), type = ds.readByte(),
      title = ds.readUTF8(ds.readShort()), slots = ds.readByte();
    writeln "open window $$int:id";
  }
  void readPlayerCloseWindow() {
    auto id = ds.readByte();
    writeln "close window $$int:id";
  }
  void readPacket() {
    considerPing;
    using SelectSet ss {
      add(sock, read => true);
      select timeout => 0;
      if !isReady(sock, read => true) return;
    }
    auto kind = ds.readByte();
    if kind == 0x00 readPing();
    else if kind == 0x01 readLoginRequest();
    else if kind == 0x02 readHandshake();
    else if kind == 0x03 readChatMessage();
    else if kind == 0x07 readPlayerUse();
    else if kind == 0x0a readPlayerOnGround();
    else if kind == 0x0b readPlayerPos();
    else if kind == 0x0c readPlayerLook();
    else if kind == 0x0d readPlayerPosLook();
    else if kind == 0x0e readPlayerDigging();
    else if kind == 0x10 readPlayerHoldingChange();
    else if kind == 0x12 readPlayerAnimation();
    else if kind == 0x13 readPlayerEntityAction();
    else if kind == 0x64 readPlayerOpenWindow();
    else if kind == 0x65 readPlayerCloseWindow();
    else if kind == 0xff removeSelf(quietly => false);
    else {
      raise-error new Error "Unknown packet: $$int:kind";
    }
  }
}

import simplex;

void main() {
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
  auto dg1 = delegate byte(vec3i pos) {
    float noise3x(vec3f v) {
      return noise3 vec3f(v.x + noise3(v), v.y + noise3(-v), v.z);
    }
    auto val =
    - noise3x vec3f(pos.x / 64f, pos.y / 64f, pos.z / 64f) * 32
    + noise3x vec3f(pos.x / 32f, pos.y / 32f, pos.z / 32f) * 16
    + noise3x vec3f(pos.x / 16f, pos.y / 16f, pos.z / 16f) * 8
    // + noise3x vec3f(pos.x /  8f, pos.y /  8f, pos.z /  8f) * 4
    ;
    val += pos.y - 60;
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
