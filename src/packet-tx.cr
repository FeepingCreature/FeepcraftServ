module packet-tx;

import std.socket, std.zlib;
import bigendian, world, drop, base, item;

class PacketTx {
  Socket socket;
  void init(Socket s) socket = s;
  void sendPacket(byte kind, byte[] data = byte[]:(null x 2)) {
    socket.send void[]:(&kind#[0..1]);
    if data.length socket.send void[]:data;
  }
  void sendLoginResponse(int eid, int protver, string name, long seed, byte dimension) {
    byte[auto~] data;
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
  void sendInventory(Item[] items) {
    byte[auto~] data;
    data ~= 0; // inv
    data ~= toField short:items.length;
    for auto item <- items
      if item {
        data ~= toField item.id;
        data ~= byte:1;
        data ~= toField short:0;
      } else {
        data ~= toField short:-1;
      }
    sendPacket(0x68, data[]);
    data.free;
  }
  void sendMapChunk(vec3i intPos, vec3i intSize, World.Chunk ch) {
    byte[auto~] data;
    data ~= toField intPos.x;
    data ~= toField short:intPos.y;
    data ~= toField intPos.z;
    data ~= *byte*:&intSize.x;
    data ~= *byte*:&intSize.y;
    data ~= *byte*:&intSize.z;
    byte[auto~] types, metadata, light, skylight;
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
  void sendPickupItemAnim(int eid, Drop d) {
    byte[auto~] data;
    data ~= toField d.eid;
    data ~= toField eid;
    sendPacket(0x16, data[]);
    data.free;
  }
  void sendPlayerPosLook(double x, y, z, float yaw, pitch, bool onGround) {
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
  void sendEntitySpawn(int eid, string name, abs-vec3i pos, byte yaw, byte pitch) {
    byte[auto~] data;
    data ~= toField eid;
    data ~= name.encodeUCS2();
    data ~= toField pos.x;
    data ~= toField pos.y;
    data ~= toField pos.z;
    data ~= yaw; // rotation
    data ~= pitch; // pitch
    data ~= toField short:0; // current item
    sendPacket(0x14, data[]);
    data.free;
  }
  void sendPosLook(int eid, abs-vec3i pos, byte yaw, byte pitch) {
    ubyte[auto~] data;
    data ~= toField eid;
    data ~= toField pos.x;
    data ~= toField pos.y;
    data ~= toField pos.z;
    data ~= yaw;
    data ~= pitch;
    sendPacket(0x22, data[]);
    data.free;
  }
  void sendBlockUpdate(vec3i worldPos, byte newval) {
    byte[auto~] data;
    data ~= toField worldPos.x;
    data ~= *byte*:&worldPos.y;
    data ~= toField worldPos.z;
    data ~= newval;
    data ~= byte:0;
    sendPacket(0x35, data[]);
    data.free;
  }
  void sendPlayerAnim(int eid, byte anim) {
    byte[auto~] data;
    data ~= toField eid;
    data ~= anim;
    sendPacket(0x12, data[]);
    data.free;
  }
  void sendItemSpawn(Drop dr) using dr {
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
    sendPacket(0x15, data[]);
    data.free;
  }
  void sendEntityRemove(int eid) {
    byte[auto~] data;
    data ~= toField eid;
    sendPacket(0x1d, data[]);
    data.free;
  }
  void sendKick() {
    sendPacket(0xff);
    socket.close;
  }
}
