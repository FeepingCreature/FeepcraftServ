module base;

import std.socket;

alias abs-vec3i = vec3i; // absolute world pos

shared int eidCount = 1;

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
