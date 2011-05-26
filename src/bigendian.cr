module bigendian;

import c.arpa.inet; // hton_

long ntohq(long l) {
  byte[] bs = byte*:&l #[0..8];
  bs[(0, 1, 2, 3, 4, 5, 6, 7)] = bs[(7, 6, 5, 4, 3, 2, 1, 0)];
  return l;
}

alias htonq = ntohq;

class BigEndianDataStream {
  byte[auto~] buffer;
  string delegate() stepDg;
  bool delegate() ivalidDg;
  void init(string delegate() sd, bool delegate() bd) (stepDg, ivalidDg) = (sd, bd);
  void readMore() {
    if !ivalidDg() raise-error new Error "DataStream empty. ";
    buffer ~= byte[]:stepDg();
  }
  byte[] take(int sz) {
    while buffer.length < sz
      readMore();
    auto res = buffer[0..sz];
    buffer = type-of buffer: buffer[sz .. $];
    return res;
  }
  byte readByte() {
    return take 1 #[0];
  }
  short readShort() {
    return short[]: take 2 #[0].ntohs();
  }
  int readInt() {
    return int[]: take 4 #[0].ntohl();
  }
  long readLong() {
    return long[]: take 8 #[0].ntohq();
  }
  float readFloat() {
    // return float[]: take 4 #[0];
    auto res = readInt();
    return *float*: &res;
  }
  double readDouble() {
    // return double[]: take 8 #[0];
    auto res = readLong();
    return *double*: &res;
  }
  string readUTF8(int len) {
    return string: take len;
  }
  string readUCS2(int len) {
    auto chars = short[]: take len;
    char[auto~] res;
    for short ch <- chars {
      ch = ntohs ch;
      if ch > 127
        raise-error new Error "Extended UTF character in UCS2: $$int:ch! ";
      res ~= char:*byte*:&ch;
    }
    return res[];
  }
}

byte x 2 toField(short s) { s = s.htons; return byte x 2: s; }
byte x 4 toField(int i) { i = i.htonl; return byte x 4: i; }
byte x 8 toField(long l) { l = l.htonq; return byte x 8: l; }
byte x 4 toField(float f) { return toField *int*:&f; }
byte x 8 toField(double d) { return toField *long*:&d; }

byte[] encodeUCS2(string s) {
  byte[auto~] res;
  if s.length > 65535 raise-error new Error "Can't UCS2 encode strings longer than 65535! ";
  res ~= toField short:s.length;
  for auto ch <- s {
    res ~= byte:0;
    res ~= byte:ch;
  }
  return res[];
}
