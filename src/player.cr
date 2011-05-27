module player;

import drop, item, server, world, base, bigendian, packet-tx;
import std.socket, std.stream, std.time;

class Inventory {
  (Item, int)[] items;
  void init() {
    items = new (Item, int)[] 45;
  }
  void sendMe(PacketTx tx) {
    tx.sendInventory items;
  }
  void addItem(Item it) {
    for int i <- seq(36..45, 9..36) {
      writeln "look at $i";
      alias item = items[i];
      if item[0] && item[0].id == it.id {
        item[1] ++;
        return;
      }
      if !item[0] {
        item = (it, 1);
        return;
      }
    }
    raise-error new Error "Inventory full! ";
  }
}

class Player : IPlayer {
  Server server;
  World world;
  Socket socket;
  string name;
  int eid;
  BigEndianDataStream ds;
  PacketTx tx;
  Inventory inv;
  
  double x, y, z, stance;
  float yaw, pitch;
  bool onGround;
  double lastPing;
  vec2i[] loadedChunks;
  vec2i lastPlayerChunkPos;
  vec3i lastPlayerBlockPos;
  Player[] otherPlayers() return [for pl <- server.selectOthers this: Player: pl].eval;
  Socket getSocket() return socket;
  string getName() return name;
  void init(Server server, World world, Socket socket) {
    this.server = server;
    this.world = world;
    inv = new Inventory;
    (x, y, z) = (8.0, 64.0, 8.0);
    stance = y + 2;
    this.socket = socket;
    ds = new BigEndianDataStream(readDg &socket.recv #.(&step, &ivalid));
    tx = new PacketTx socket;
    lastPing = sec();
  }
  byte yawByte() { int iyaw = int:(yaw * 256f / 360); return *byte*: &iyaw; }
  byte pitchByte() { int ipitch = int:(pitch * 256f / 360); return *byte*: &ipitch; }
  void sendChatMessage(string msg) tx.sendChatMessage msg;
  void removeEntity(int eid) tx.sendEntityRemove eid;
  vec3i readBlockPosition() {
    int x = ds.readInt(), y = ds.readByte(), z = ds.readInt();
    return vec3i(x, y, z);
  }
  void sendNewChunk(vec2i v) {
    tx.sendPreChunk(v, true);
    vec3i pos = vec3i(v.(x << 4, 0, y << 4));
    tx.sendMapChunk(pos, vec3i(15, 63, 15), world.lookupChunkAt pos);
    pos.y += 64;
    tx.sendMapChunk(pos, vec3i(15, 63, 15), world.lookupChunkAt pos);
  }
  void unloadChunk(vec2i v) {
    tx.sendPreChunk(v, false);
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
      if |d.pos - playerAbsPos| / 32 < 1.6 {
        tx.sendPickupItemAnim (eid, d);
        for auto player <- server.players
          (Player:player).tx.sendEntityRemove d.eid;
        world.removeDrop d;
        inv.addItem new Item 3;
        inv.sendMe tx;
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
  void readHandshake() {
    auto str = ds.readUCS2(ds.readShort() * 2);
    tx.sendPacket(2, encodeUCS2("-"));
  }
  void spawnEntityFor(Player pl) {
    tx.sendEntitySpawn(eid, name, vec3i(int:(x * 32), int:(y * 32), int:(z * 32)), yawByte(), pitchByte());
  }
  void readLoginRequest() {
    auto protver = ds.readInt();
    writeln "Protocol version: $protver";
    name = ds.readUCS2(ds.readShort() * 2);
    writeln "Logging in: $name";
    ds.readLong(); // map seed
    ds.readByte(); // dimension
    eid = eidCount ++;
    using tx {
      sendLoginResponse(eid, 11, string:(null x 2), 0, 0);
      sendSpawnLocation(0, 64, 0);
      sendEmptyInventory();
      playerMovementChecks();
      sendPlayerPosLook(x, y, z, yaw, pitch, onGround);
      sendChatMessage "<server> Hi! I am feepserv!";
      sendChatMessage "<server> I am pretty crashy, so don't";
      sendChatMessage "<server> get worried when you disconnect! ";
    }
    server.removeConnectingPlayer(this);
    server.addPlayer(this);
    server.broadcast("[server] $name has joined! ");
    // spawn other players for me
    for auto other <- otherPlayers() {
      other.spawnEntityFor this;
      spawnEntityFor other;
    }
  }
  void updatePosLookFor(Player pl) {
    using pl this.tx.sendPosLook(eid, vec3i(int:(x * 32), int:(y * 32), int:(z * 32)), yawByte(), pitchByte());
  }
  void readChatMessage() {
    auto msg = ds.readUCS2(ds.readShort() * 2);
    auto line = "<$name> $msg";
    writeln line;
    server.broadcast line;
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
    tx.sendPacket(0);
  }
  void updateBlock(vec3i worldPos, byte newval) {
    auto chunkPos = vec3i(worldPos.(x >> 4, y >> 6, z >> 4));
    bool found;
    while auto ch <- loadedChunks && !found
      if (ch == chunkPos.xz)
        found = true;
    if !found return; // not visible
    tx.sendBlockUpdate(worldPos, newval);
  }
  void animatePlayer(Player pl, byte anim) {
    tx.sendPlayerAnim(pl.eid, anim);
  }
  void spawnItem(Drop dr) {
    tx.sendItemSpawn(dr);
    writeln "$name: spawn item at $(dr.pos) ($$short:dr.item.id)";
  }
  void broadcastUpdateBlock(vec3i pos, byte b) {
    for auto player <- [for pl <- server.players: Player: pl] {
      player.updateBlock(pos, b);
    }
  }
  void readPlayerDigging() {
    byte status = ds.readByte();
    auto pos = readBlockPosition();
    byte face = ds.readByte();
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
        broadcastUpdateBlock(pos, 0);
      }
    }
    writeln "Player digging at $x, $$int:y, $z (face $$int:face, status $$int:status)";
  }
  void readPlayerHoldingChange() {
    short slotId = ds.readShort();
    writeln "Player switched to slot $$int:slotId";
  }
  void sendPing() { lastPing = sec(); tx.sendPacket(0); }
  void readPing() { sendPing; }
  void considerPing() {
    if (float:(sec() - lastPing) > 1.0) sendPing;
  }
  void removeSelf(bool quietly) {
    for auto other <- otherPlayers() {
      other.removeEntity eid;
    }
    tx.sendKick();
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
  void readPlayerClickWindow() {
    auto
      id = ds.readByte(), slot = ds.readShort(),
      right-click = bool:ds.readByte(), action-number = ds.readShort(),
      shift = bool:ds.readByte(), item-id = ds.readShort();
    byte item-count; short item-uses;
    if (item-id != short:-1) {
      item-count = ds.readByte(); item-uses = ds.readShort();
    }
    tx.sendTransactionAccept(0, action-number, true);
    writeln "click window $$int:id";
    writeln " slot $slot, right-click $right-click, action number $action-number, shift: $shift";
    writeln " item-id $item-id, item-count $$int:item-count, item-uses $item-uses";
  }
  void readPlayerPlacingBlock() {
    auto pos = readBlockPosition();
    auto dir = ds.readByte();
    auto block-or-item-id = ds.readShort();
    byte amount; short damage;
    if block-or-item-id >= 0 {
      amount = ds.readByte();
      damage = ds.readShort();
      if (dir != -1) {
        auto real-pos = pos + vec3i.([-Y, Y, -Z, Z, -X, X][dir]);
        broadcastUpdateBlock(real-pos, *byte*:&block-or-item-id);
        writeln "player placed: $block-or-item-id at $real-pos (dir $$int:dir)";
      } else writeln "player placed: special case -1";
    }
  }
  void readPacket() {
    considerPing;
    using SelectSet ss {
      add(socket, read => true);
      select timeout => 0;
      if !isReady(socket, read => true) return;
    }
    auto kind = ds.readByte();
    // writeln "$name> $$int:kind";
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
    else if kind == 0x0f readPlayerPlacingBlock();
    else if kind == 0x10 readPlayerHoldingChange();
    else if kind == 0x12 readPlayerAnimation();
    else if kind == 0x13 readPlayerEntityAction();
    else if kind == 0x64 readPlayerOpenWindow();
    else if kind == 0x65 readPlayerCloseWindow();
    else if kind == 0x66 readPlayerClickWindow();
    else if kind == 0xff removeSelf(quietly => false);
    else {
      raise-error new Error "Unknown packet: $$int:kind";
    }
  }
}
