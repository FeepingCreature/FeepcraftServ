module world;

import drop;

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
