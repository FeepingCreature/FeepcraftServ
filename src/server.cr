module server;

import base, std.thread, std.socket;

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
