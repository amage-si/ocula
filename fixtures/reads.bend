import Base

def cases() -> List<(String & (U32 & U32))>:
  [("io-empty", (0, 0)),
   ("io-small", (100, 1489580789)),
   ("io-chunk-minus-one", (65535, 426112482)),
   ("io-chunk", (65536, 2971526817)),
   ("io-chunk-plus-one", (65537, 1935827221)),
   ("io-limit", (2097152, 4071163044)),
   ("io-overlimit", (2097153, 55255416))]

def short_read_crc() -> U32:
  1323112775
