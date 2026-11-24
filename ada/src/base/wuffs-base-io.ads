--  I/O primitives: the io_reader and io_writer methods of Wuffs' base
--  package, over array parameters and index values instead of C pointers.
--
--  C: wuffs/internal/cgen/base/io-public.h (io_buffer, io_buffer_meta),
--  io-private.h (wuffs_private_impl__io_*), and the code that
--  wuffs/internal/cgen/builtin.go and var.go emit inline for I/O methods.
--
--  Model
--  -----
--  An I/O buffer is a Bytes array (owned by the caller, passed to every
--  operation that touches bytes) plus a Buffer_Meta value: wi, ri, pos,
--  closed, as in C.
--
--  While a Wuffs function runs, C keeps four pointers per io_reader or
--  io_writer argument: io0 (history base), io1 (lower bound for undo),
--  iop (the cursor) and io2 (upper bound).  Here they are the fields of a
--  Reader or Writer record, which also carries a copy of the meta's pos
--  (and, for a Reader, closed).
--
--  Addressing convention of this package: EVERY position is a
--  First_Offset, a count of elements from the start of the array it comes
--  with.  Field or parameter value K denotes element Data (Data'First +
--  K).  That holds for Buffer_Meta.Wi / Ri, for the four cursor fields and
--  for every Xxx_Offset and Xxx_Base parameter.  No subprogram here takes
--  an Ada index.  (Wuffs.Base.Endian and Wuffs.Base.Slices take Ada
--  indices.)  Readable (Reader) or writable (Writer) elements are offsets
--  Iop .. Io2 - 1.
--
--  A Wuffs `mark` (io_reader.mark(), io_writer.mark()) is Iop - Io0, as in
--  C, so marks stay meaningful to Count_Since and Since_Offset.
--
--  Every operation that reads or writes Data requires Valid (Data, R) (or
--  W): the cursor's upper bound lies within the array.  Preconditions
--  beyond that are the ones the Wuffs compiler proves at each call site
--  (for example length() >= 4 before peek_u32le()).
--
--  Protocols for generated code
--  ----------------------------
--  These mirror what wuffs/internal/cgen (var.go, statement.go) emits.
--  Generated code should not assign cursor or meta fields itself; each
--  step below is one call.  M is the Buffer_Meta of the buffer, R / W the
--  cursor, Data the array.
--
--  Function with an io_reader (io_writer) argument:
--    entry:                      R := To_Reader (M);
--                                W := To_Writer (M, Data'Length);
--    exit, and every suspension: Save (M, R);  Save (M, W);
--
--  Passing the buffer to a callee (another Wuffs function):
--    Save (M, R);  callee (Data, M, ...);  Reload (R, M);
--    (same for W).  The callee builds its own cursor from M.
--
--  io_bind (io: x, data: d, history_position: h) { body }:
--    declare a new meta and cursor for d, for the body only:
--      M2 := Reader_Meta (d'Length, False, h);  R2 := Reader_Set (d'Length, h);
--      M2 := Writer_Meta (h);                   W2 := Writer_Set (d'Length, h);
--    Inside the body x means (d, M2, R2).  Nothing is copied back at the
--    end (C restores its saved pointers; the bound buffer is a local).
--
--  io_limit (io: r, limit: n) { body }, reader:
--    Begin_Limit (M, R, n, Saved);  body;  End_Limit (M, R, Saved);
--    Begin_Limit shortens both the cursor and the meta (M.Wi, M.Closed),
--    which is how callees inside the body see the limit, as in C.
--
--  io_limit (io: w, limit: n) { body }, writer:
--    Begin_Limit (W, n, Saved_Io2);  body;  End_Limit (W, Saved_Io2);
--    C shortens the buffer's data.len here, not the meta.  So a callee
--    inside the body must be given the shortened array,
--    Data (Data'First .. Data'First + W.Io2 - 1), not all of Data.
--
--  io_forget_history (io: w) { body }, writer only (upstream rejects it
--  for readers):
--    Begin_Forget_History (M, W, Saved);  body;
--    End_Forget_History (M, W, Saved);
--    Inside the body the history is empty at first (Io0 = Io1 = Iop), and
--    C re-bases the buffer at the old M.Wi.  So a callee inside the body
--    gets the array from Forgotten_Base (Saved) on,
--    Data (Data'First + Forgotten_Base (Saved) .. Data'First + W.Io2 - 1),
--    and the calls around it are Save_Forgotten (M, W, Saved) and
--    Reload_Forgotten (W, M, Saved) instead of Save and Reload.
--
--  Overlap
--  -------
--  Where an operation takes two arrays (one `in out`, one `in`) they must
--  not share any element; SPARK assumes it and the proof says nothing
--  otherwise.  The C counterparts are memmoves and tolerate overlap, so
--  each such operation has a _Within form for the case that both operands
--  lie in one array (for example a reader and a writer bound to parts of
--  the same work buffer):
--
--    disjoint arrays                 both in one array (memmove)
--    ------------------------------  -----------------------------------
--    Limited_Copy_U32_To_Slice       Limited_Copy_U32_To_Slice_Within
--    Copy_From_Slice                 Copy_From_Slice_Within
--    Limited_Copy_U32_From_Slice     Limited_Copy_U32_From_Slice_Within
--    Limited_Copy_U32_From_Reader    Limited_Copy_U32_From_Reader_Within
--
--  A _Within form takes the one enclosing array, and for each operand
--  where in it the operand's own array starts (R_Base, W_Base) or lies
--  (Xxx_Offset, Xxx_Length).  The history copies work within the writer's
--  own array by nature and need no second form.
--
--  Method table
--  ------------
--  io_reader method                   Ada (R : Reader)
--  ---------------------------------  ----------------------------------
--  length(), is_closed()              Length (R), Is_Closed (R)
--  mark(), position()                 Mark (R), Position (R)
--  count_since(mark)                  Count_Since (R, Mark)
--  since(mark)                        Since_Offset / Since_Length (R, Mark)
--  can_undo_byte()                    Can_Undo_Byte (R)
--  peek_undo_byte(), undo_byte!()     Peek_Undo_Byte (Data, R), Undo_Byte (R)
--  peek_uNNxe(), peek_uNNxe_as_uMM()  Peek_UNNxE (Data, R), then convert
--  peek_u8_at(o), peek_u64le_at(o)    Peek_U8_At, Peek_U64LE_At (Data, R, O)
--  match7(a)                          Match7 (Data, R, A)
--  skip_u32_fast!(actual, worst)      Skip_U32_Fast (R, Actual)
--  limited_copy_u32_to_slice!(n, s)   Limited_Copy_U32_To_Slice
--  read_u8?() and read_u8_as_uMM?()   Read_U8 (after a Length (R) = 0 test)
--  read_uNNxe?(), ..._as_uMM?()       Peek_UNNxE + Skip_U32_Fast if Length
--                                     allows, else Read_Step_LE / _BE
--  skip?(n), skip_u32?(n)             Skip
--  (statements)                       see "Protocols" above
--
--  io_writer method                   Ada (W : Writer)
--  ---------------------------------  ----------------------------------
--  length()                           Length (W)
--  mark(), position()                 Mark (W), Position (W)
--  history_length()                   History_Length (W)
--  history_position()                 History_Position (W)
--  count_since(mark), since(mark)     Count_Since, Since_Offset / _Length
--  can_undo_byte() etc.               Can_Undo_Byte, Peek_Undo_Byte, Undo_Byte
--  write_u8?(a)                       Write_U8_Fast (after a Length test)
--  write_uNNxe_fast!(a)               Write_UNNxE_Fast (Data, W, A)
--  copy_from_slice!(s)                Copy_From_Slice
--  limited_copy_u32_from_slice!       Limited_Copy_U32_From_Slice
--  limited_copy_u32_from_reader!      Limited_Copy_U32_From_Reader
--  limited_copy_u32_from_history*!    Limited_Copy_U32_From_History* (7)
--  (statements)                       see "Protocols" above
--
--  Not here: io_reader.valid_utf_8_length (needs the UTF-8 code, a later
--  milestone); write_u16be? .. write_u64le? (upstream's C generator does
--  not implement them either).

with Wuffs.Base.Endian;
with Wuffs.Base.Ints;

package Wuffs.Base.IO with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   -----------------
   -- Buffer_Meta --
   -----------------

   --  C: wuffs_base__io_buffer_meta.  Data (Data'First + Ri ..
   --  Data'First + Wi - 1) has been written and not yet read.
   type Buffer_Meta is record
      Wi     : Index   := 0;      --  write index, counted from Data'First
      Ri     : Index   := 0;      --  read index, counted from Data'First
      Pos    : U64     := 0;      --  stream position of Data'First
      Closed : Boolean := False;  --  no further writes are expected
   end record
   with Predicate => Ri <= Wi;

   --  C: wuffs_base__io_buffer__is_valid.
   function Is_Valid (Data : Bytes; M : Buffer_Meta) return Boolean is
     (M.Wi <= Data'Length);

   --  C: wuffs_base__empty_io_buffer_meta.
   Empty_Meta : constant Buffer_Meta := (Wi => 0, Ri => 0, Pos => 0, Closed => False);

   --  Meta of a buffer whose Data_Length bytes are all there to be read.
   --  C: wuffs_base__slice_u8__reader (History_Position = 0) and the meta
   --  part of wuffs_private_impl__io_reader__set (Closed = False).
   function Reader_Meta
     (Data_Length : Index; Closed : Boolean; History_Position : U64 := 0) return Buffer_Meta
   is (Wi => Data_Length, Ri => 0, Pos => History_Position, Closed => Closed);

   --  Meta of a buffer with nothing written yet.  C:
   --  wuffs_base__slice_u8__writer (History_Position = 0) and the meta
   --  part of wuffs_private_impl__io_writer__set.
   function Writer_Meta (History_Position : U64 := 0) return Buffer_Meta is
     (Wi => 0, Ri => 0, Pos => History_Position, Closed => False);

   --  C: wuffs_base__io_buffer__reader_length, __reader_position,
   --  __writer_length, __writer_position.
   function Reader_Length (M : Buffer_Meta) return Index is (M.Wi - M.Ri);

   function Reader_Position (M : Buffer_Meta) return U64 is
     (Ints.Sat_Add_U64 (M.Pos, U64 (M.Ri)));

   function Writer_Length (Data : Bytes; M : Buffer_Meta) return U64 is
     (U64 (Data'Length - M.Wi))
   with Pre => Is_Valid (Data, M);

   function Writer_Position (M : Buffer_Meta) return U64 is
     (Ints.Sat_Add_U64 (M.Pos, U64 (M.Wi)));

   --  C: wuffs_base__io_buffer__compact_retaining.  Moves the unread bytes,
   --  preceded by up to History_Retain_Length already-read bytes, to the
   --  start of Data, and adjusts M.  N is the distance moved: the number of
   --  bytes dropped from the front.
   procedure Compact_Retaining
     (Data                  : in out Bytes;
      M                     : in out Buffer_Meta;
      History_Retain_Length : U64;
      N                     : out Index)
   with
     Pre  => Is_Valid (Data, M),
     Post => Is_Valid (Data, M)
       and then U64 (M.Ri) = Ints.Min_U64 (U64 (M'Old.Ri), History_Retain_Length)
       and then N = M'Old.Ri - M.Ri
       and then M.Wi = M'Old.Wi - N
       and then M.Pos = Ints.Sat_Add_U64 (M'Old.Pos, U64 (N))
       and then M.Closed = M'Old.Closed
       and then (for all J in Data'Range =>
                   (if J - Data'First < M.Wi
                    then Data (J) = Data'Old (J + N)
                    else Data (J) = Data'Old (J)));

   --  C: wuffs_base__io_buffer__compact.  Compact_Retaining with nothing
   --  retained: N is the old M.Ri and the new M.Ri is zero.
   procedure Compact (Data : in out Bytes; M : in out Buffer_Meta; N : out Index) with
     Pre  => Is_Valid (Data, M),
     Post => Is_Valid (Data, M)
       and then M.Ri = 0
       and then N = M'Old.Ri
       and then M.Wi = M'Old.Wi - N
       and then M.Pos = Ints.Sat_Add_U64 (M'Old.Pos, U64 (N))
       and then M.Closed = M'Old.Closed
       and then (for all J in Data'Range =>
                   (if J - Data'First < M.Wi
                    then Data (J) = Data'Old (J + N)
                    else Data (J) = Data'Old (J)));

   --  C: wuffs_private_impl__io__count_since.  Index is a mark-like value
   --  (Iop - Io0).
   function Count_Since (Mark : U64; Index : U64) return U64 is
     (if Index >= Mark then Index - Mark else 0);

   ------------
   -- Reader --
   ------------

   type Reader is record
      Io0    : Index   := 0;      --  history base; marks count from here
      Io1    : Index   := 0;      --  Iop at function entry; undo stops here
      Iop    : Index   := 0;      --  next element to read
      Io2    : Index   := 0;      --  one past the last readable element
      Pos    : U64     := 0;      --  stream position of Data'First
      Closed : Boolean := False;  --  no more data will follow Io2
   end record
   with Predicate => Io0 <= Io1 and then Io1 <= Iop and then Iop <= Io2;

   function Valid (Data : Bytes; R : Reader) return Boolean is (R.Io2 <= Data'Length);

   --  The cursor for a function's io_reader argument, at entry.
   function To_Reader (M : Buffer_Meta) return Reader is
     (Io0 => 0, Io1 => M.Ri, Iop => M.Ri, Io2 => M.Wi, Pos => M.Pos, Closed => M.Closed);

   --  Stores the cursor position back, at exit or before passing the
   --  buffer on: M.Ri := R.Iop.
   procedure Save (M : in out Buffer_Meta; R : Reader) with
     Inline_Always,
     Pre  => R.Iop <= M.Wi,
     Post => M = (M'Old with delta Ri => R.Iop);

   --  The cursor (C: wuffs_private_impl__io_reader__set) for an io_bind of
   --  a reader to a Data_Length byte array; use with Reader_Meta
   --  (Data_Length, False, History_Position).
   function Reader_Set (Data_Length : Index; History_Position : U64) return Reader is
     (Io0 => 0, Io1 => 0, Iop => 0, Io2 => Data_Length,
      Pos => History_Position, Closed => False);

   function Length (R : Reader) return U64 is (U64 (R.Io2 - R.Iop));

   function Is_Closed (R : Reader) return Boolean is (R.Closed);

   function Mark (R : Reader) return U64 is (U64 (R.Iop - R.Io0));

   function Position (R : Reader) return U64 is
     (Ints.Sat_Add_U64 (R.Pos, U64 (R.Iop - R.Io0)));

   function Count_Since (R : Reader; Mark : U64) return U64 is
     (Count_Since (Mark, U64 (R.Iop - R.Io0)));

   --  r.since(mark) is the Since_Length (R, Mark) elements of Data starting
   --  at Data'First + Since_Offset (R, Mark): the bytes consumed since the
   --  mark, or nothing if the mark is ahead of the cursor.
   function Since_Length (R : Reader; Mark : U64) return Index is
     (Index (Count_Since (R, Mark)));

   function Since_Offset (R : Reader; Mark : U64) return Index is
     (if U64 (R.Iop - R.Io0) >= Mark then R.Io0 + Index (Mark) else 0)
   with Post => Since_Offset'Result + Since_Length (R, Mark) <= R.Iop;

   function Can_Undo_Byte (R : Reader) return Boolean is (R.Iop > R.Io1);

   function Peek_Undo_Byte (Data : Bytes; R : Reader) return U8 is
     (Data (Data'First + (R.Iop - 1)))
   with Pre => Valid (Data, R) and then Can_Undo_Byte (R);

   procedure Undo_Byte (R : in out Reader) with
     Inline_Always,
     Pre  => Can_Undo_Byte (R),
     Post => R = (R'Old with delta Iop => R'Old.Iop - 1);

   --  Peeks do not move the cursor.  The Wuffs peek_uNNxe_as_uMM variants
   --  are these followed by a widening conversion.

   function Peek_U8 (Data : Bytes; R : Reader) return U8 is
     (Endian.Peek_U8 (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 1;

   function Peek_U16BE (Data : Bytes; R : Reader) return U16 is
     (Endian.Peek_U16BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 2;

   function Peek_U16LE (Data : Bytes; R : Reader) return U16 is
     (Endian.Peek_U16LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 2;

   function Peek_U24BE (Data : Bytes; R : Reader) return U32 is
     (Endian.Peek_U24BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 3;

   function Peek_U24LE (Data : Bytes; R : Reader) return U32 is
     (Endian.Peek_U24LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 3;

   function Peek_U32BE (Data : Bytes; R : Reader) return U32 is
     (Endian.Peek_U32BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 4;

   function Peek_U32LE (Data : Bytes; R : Reader) return U32 is
     (Endian.Peek_U32LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 4;

   function Peek_U40BE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U40BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 5;

   function Peek_U40LE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U40LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 5;

   function Peek_U48BE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U48BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 6;

   function Peek_U48LE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U48LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 6;

   function Peek_U56BE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U56BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 7;

   function Peek_U56LE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U56LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 7;

   function Peek_U64BE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U64BE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 8;

   function Peek_U64LE (Data : Bytes; R : Reader) return U64 is
     (Endian.Peek_U64LE (Data, Data'First + R.Iop))
   with Pre => Valid (Data, R) and then Length (R) >= 8;
   --  The byte Offset elements after the cursor.
   function Peek_U8_At (Data : Bytes; R : Reader; Offset : U32) return U8 is
     (Data (Data'First + (R.Iop + Index (Offset))))
   with Pre => Valid (Data, R) and then Length (R) > U64 (Offset);

   function Peek_U64LE_At (Data : Bytes; R : Reader; Offset : U32) return U64 is
     (Endian.Peek_U64LE (Data, Data'First + (R.Iop + Index (Offset))))
   with Pre => Valid (Data, R) and then Length (R) >= U64 (Offset) + 8;

   --  C: wuffs_private_impl__io_reader__match7.  Whether the upcoming
   --  bytes start with a prefix of up to 7 bytes.  The low 3 bits of A are
   --  the prefix length n; prefix byte k (from 0) is bits 8 * (k + 1) ..
   --  8 * (k + 1) + 7 of A.  Returns 0 for a match, 2 for a mismatch, 1 if
   --  the available bytes match so far but fewer than n are available and
   --  the reader is not closed.  Does not move the cursor.
   --
   --  An empty prefix (n = 0) always matches.  (With 8 or more bytes
   --  available the C code shifts a uint64_t by 64 for n = 0, which is
   --  undefined behaviour in C.)
   function Match7 (Data : Bytes; R : Reader; A : U64) return U32 with
     Pre  => Valid (Data, R),
     Post => Match7'Result <= 2
       and then (if Match7'Result = 1 then Length (R) < (A and 7) and then not R.Closed)
       and then (if (A and 7) = 0 then Match7'Result = 0);

   --  Advances the cursor by Actual.  (The Wuffs method's second argument,
   --  worst_case, exists for the Wuffs compiler's proof only; it shows
   --  Actual <= worst_case <= length().)
   procedure Skip_U32_Fast (R : in out Reader; Actual : U32) with
     Inline_Always,
     Pre  => U64 (Actual) <= Length (R),
     Post => R = (R'Old with delta Iop => R'Old.Iop + Index (Actual));

   --  C: wuffs_private_impl__io_reader__limited_copy_u32_to_slice.  Copies
   --  N bytes from the cursor to the start of Dst and advances the cursor
   --  by N, where N is the smallest of Up_To, Dst'Length and Length (R).
   --
   --  DISJOINT ONLY: Data and Dst must not share any element.  If they are
   --  parts of one array use Limited_Copy_U32_To_Slice_Within.
   procedure Limited_Copy_U32_To_Slice
     (Data  : Bytes;
      R     : in out Reader;
      Up_To : U32;
      Dst   : in out Bytes;
      N     : out U32)
   with
     Pre  => Valid (Data, R),
     Post => Offset (N) = Offset'Min
                            (Offset'Min (Offset (Up_To), Dst'Length), R'Old.Io2 - R'Old.Iop)
       and then R = (R'Old with delta Iop => R'Old.Iop + Index (N))
       and then (for all J in Dst'Range =>
                   (if J - Dst'First < Index (N)
                    then Dst (J) = Data (Data'First + R'Old.Iop + (J - Dst'First))
                    else Dst (J) = Dst'Old (J)));

   --  The inline C for read_u8?() once a byte is known to be available:
   --  V is the byte at the cursor, which advances by one.
   procedure Read_U8 (Data : Bytes; R : in out Reader; V : out U8) with
     Inline_Always,
     Pre  => Valid (Data, R) and then Length (R) >= 1,
     Post => V = Peek_U8 (Data, R'Old)
       and then R = (R'Old with delta Iop => R'Old.Iop + 1);

   --  The slow path of read_uNNle?() / read_uNNbe?(), for when fewer than
   --  NN / 8 bytes are available: the value is assembled one byte per
   --  call in a U64 scratch word that survives suspension.  This is the
   --  loop body that upstream's writeReadUxxAsUyy emits, bit for bit.
   --
   --  Protocol: set Scratch to 0, then repeat { if Length (R) = 0 then
   --  suspend with "$short read" (and resume here); Read_Step_xx (...);
   --  exit when Done }.  Last_Shift is NN - 8.  When Done, Value is the
   --  NN-bit result.  Otherwise Value is 0.
   --
   --  The scratch word keeps the count of bits read so far in its top
   --  (LE) or bottom (BE) byte.  The precondition on Scratch holds
   --  whenever the protocol is followed.
   subtype Read_Last_Shift is U32 with
     Static_Predicate => Read_Last_Shift in 8 | 16 | 24 | 32 | 40 | 48 | 56;

   procedure Read_Step_LE
     (Data       : Bytes;
      R          : in out Reader;
      Scratch    : in out U64;
      Last_Shift : Read_Last_Shift;
      Done       : out Boolean;
      Value      : out U64)
   with
     Pre  => Valid (Data, R) and then Length (R) >= 1
       and then Interfaces.Shift_Right (Scratch, 56) <= U64 (Last_Shift)
       and then Interfaces.Shift_Right (Scratch, 56) mod 8 = 0,
     Post => R = (R'Old with delta Iop => R'Old.Iop + 1)
       and then Done = (Interfaces.Shift_Right (Scratch'Old, 56) = U64 (Last_Shift))
       and then (if Done then Value = Scratch
                 else Value = 0
                   and then Interfaces.Shift_Right (Scratch, 56) =
                              Interfaces.Shift_Right (Scratch'Old, 56) + 8);

   procedure Read_Step_BE
     (Data       : Bytes;
      R          : in out Reader;
      Scratch    : in out U64;
      Last_Shift : Read_Last_Shift;
      Done       : out Boolean;
      Value      : out U64)
   with
     Pre  => Valid (Data, R) and then Length (R) >= 1
       and then (Scratch and 16#FF#) <= U64 (Last_Shift)
       and then (Scratch and 16#FF#) mod 8 = 0,
     Post => R = (R'Old with delta Iop => R'Old.Iop + 1)
       and then Done = ((Scratch'Old and 16#FF#) = U64 (Last_Shift))
       and then (if Done
                 then Value = Interfaces.Shift_Right (Scratch, 56 - Natural (Last_Shift))
                 else Value = 0
                   and then (Scratch and 16#FF#) = (Scratch'Old and 16#FF#) + 8);

   --  The inline C for skip?(n) and skip_u32?(n).  Protocol: set Scratch
   --  to n, then repeat { Skip (R, Scratch, Done); exit when Done; suspend
   --  with "$short read" (and resume here) }.  Each call consumes what is
   --  available, up to the Scratch bytes still to skip.
   procedure Skip (R : in out Reader; Scratch : in out U64; Done : out Boolean) with
     Post => Done = (Scratch'Old <= Length (R'Old))
       and then (if Done
                 then R = (R'Old with delta Iop => R'Old.Iop + Index (Scratch'Old))
                   and then Scratch = Scratch'Old
                 else R = (R'Old with delta Iop => R'Old.Io2)
                   and then Scratch = Scratch'Old - Length (R'Old));

   --  After a callee was given (Data, M): the cursor continues where the
   --  callee stopped.  C: iop = data.ptr + meta.ri.
   procedure Reload (R : in out Reader; M : Buffer_Meta) with
     Inline_Always,
     Pre  => R.Io1 <= M.Ri and then M.Ri <= R.Io2,
     Post => R = (R'Old with delta Iop => M.Ri);

   --  The io_limit statement, reader.  C: wuffs_private_impl__io_reader__limit
   --  followed by the meta update that statement.go emits:
   --
   --    n = io2 - data.ptr;                      (io2 already limited)
   --    meta.closed = meta.closed && (meta.wi <= n);
   --    meta.wi = n;
   --
   --  Begin_Limit leaves at most Up_To readable bytes (R.Io2 never grows),
   --  applies that update to M and keeps R.Closed equal to M.Closed.  The
   --  previous upper bound and closed flag go to Saved.  End_Limit puts
   --  both back, in the cursor and in the meta; the cursor position stays
   --  where the body left it.
   --
   --  Precondition M.Ri <= R.Iop: the meta's read index (as last saved) is
   --  not ahead of the cursor.  It holds after To_Reader, Save and Reload
   --  as long as no Undo_Byte went below the saved position; call
   --  Save (M, R) first if in doubt.
   type Reader_Limit_State is record
      Io2    : First_Offset := 0;
      Closed : Boolean      := False;
   end record;

   procedure Begin_Limit
     (M     : in out Buffer_Meta;
      R     : in out Reader;
      Up_To : U64;
      Saved : out Reader_Limit_State)
   with
     Pre  => M.Ri <= R.Iop,
     Post => Saved = (Io2 => R'Old.Io2, Closed => M'Old.Closed)
       and then R.Io2 = (if Length (R'Old) > Up_To
                         then R'Old.Iop + Index (Up_To) else R'Old.Io2)
       and then M = (M'Old with delta
                       Wi     => R.Io2,
                       Closed => M'Old.Closed and then M'Old.Wi <= R.Io2)
       and then R = (R'Old with delta Io2 => R.Io2, Closed => M.Closed);

   procedure End_Limit
     (M     : in out Buffer_Meta;
      R     : in out Reader;
      Saved : Reader_Limit_State)
   with
     Pre  => R.Iop <= Saved.Io2 and then M.Ri <= Saved.Io2,
     Post => R = (R'Old with delta Io2 => Saved.Io2, Closed => Saved.Closed)
       and then M = (M'Old with delta Wi => Saved.Io2, Closed => Saved.Closed);

   ------------
   -- Writer --
   ------------

   type Writer is record
      Io0 : Index := 0;  --  history base; marks count from here
      Io1 : Index := 0;  --  Iop at function entry; undo stops here
      Iop : Index := 0;  --  next element to write
      Io2 : Index := 0;  --  one past the last writable element
      Pos : U64   := 0;  --  stream position of Data'First
   end record
   with Predicate => Io0 <= Io1 and then Io1 <= Iop and then Iop <= Io2;

   function Valid (Data : Bytes; W : Writer) return Boolean is (W.Io2 <= Data'Length);

   --  The cursor for a function's io_writer argument, at entry.  A closed
   --  buffer accepts no bytes.
   function To_Writer (M : Buffer_Meta; Data_Length : Index) return Writer is
     (Io0 => 0, Io1 => M.Wi, Iop => M.Wi,
      Io2 => (if M.Closed then M.Wi else Data_Length), Pos => M.Pos)
   with Pre => M.Wi <= Data_Length;

   --  Stores the cursor position back: M.Wi := W.Iop.
   procedure Save (M : in out Buffer_Meta; W : Writer) with
     Inline_Always,
     Pre  => M.Ri <= W.Iop,
     Post => M = (M'Old with delta Wi => W.Iop);

   --  The cursor (C: wuffs_private_impl__io_writer__set) for an io_bind of
   --  a writer to a Data_Length byte array; use with Writer_Meta
   --  (History_Position).
   function Writer_Set (Data_Length : Index; History_Position : U64) return Writer is
     (Io0 => 0, Io1 => 0, Iop => 0, Io2 => Data_Length, Pos => History_Position);

   function Length (W : Writer) return U64 is (U64 (W.Io2 - W.Iop));

   function Mark (W : Writer) return U64 is (U64 (W.Iop - W.Io0));

   --  Number of bytes before the cursor that history copies may reach.
   function History_Length (W : Writer) return U64 is (U64 (W.Iop - W.Io0));

   function History_Position (W : Writer) return U64 is (W.Pos);

   function Position (W : Writer) return U64 is
     (Ints.Sat_Add_U64 (W.Pos, U64 (W.Iop - W.Io0)));

   function Count_Since (W : Writer; Mark : U64) return U64 is
     (Count_Since (Mark, U64 (W.Iop - W.Io0)));

   --  w.since(mark) is the Since_Length (W, Mark) elements of Data starting
   --  at Data'First + Since_Offset (W, Mark): the bytes written since the
   --  mark, or nothing if the mark is ahead of the cursor.
   function Since_Length (W : Writer; Mark : U64) return Index is
     (Index (Count_Since (W, Mark)));

   function Since_Offset (W : Writer; Mark : U64) return Index is
     (if U64 (W.Iop - W.Io0) >= Mark then W.Io0 + Index (Mark) else 0)
   with Post => Since_Offset'Result + Since_Length (W, Mark) <= W.Iop;

   function Can_Undo_Byte (W : Writer) return Boolean is (W.Iop > W.Io1);

   function Peek_Undo_Byte (Data : Bytes; W : Writer) return U8 is
     (Data (Data'First + (W.Iop - 1)))
   with Pre => Valid (Data, W) and then Can_Undo_Byte (W);

   procedure Undo_Byte (W : in out Writer) with
     Inline_Always,
     Pre  => Can_Undo_Byte (W),
     Post => W = (W'Old with delta Iop => W'Old.Iop - 1);

   --  After a callee was given (Data, M): the cursor continues where the
   --  callee stopped.  C: iop = data.ptr + meta.wi.
   procedure Reload (W : in out Writer; M : Buffer_Meta) with
     Inline_Always,
     Pre  => W.Io1 <= M.Wi and then M.Wi <= W.Io2,
     Post => W = (W'Old with delta Iop => M.Wi);

   --  The io_limit statement, writer.  C:
   --  wuffs_private_impl__io_writer__limit, then `data.len = io2 -
   --  data.ptr`.  Begin_Limit leaves at most Up_To writable bytes and
   --  returns the previous upper bound, which End_Limit restores.  The
   --  meta does not change.  The data.len part is the caller's: while the
   --  limit is active, a callee must be given only
   --  Data (Data'First .. Data'First + W.Io2 - 1).
   procedure Begin_Limit
     (W         : in out Writer;
      Up_To     : U64;
      Saved_Io2 : out First_Offset)
   with
     Post => Saved_Io2 = W'Old.Io2
       and then (if Length (W'Old) > Up_To
                 then W = (W'Old with delta Io2 => W'Old.Iop + Index (Up_To))
                 else W = W'Old);

   procedure End_Limit (W : in out Writer; Saved_Io2 : First_Offset) with
     Pre  => W.Iop <= Saved_Io2,
     Post => W = (W'Old with delta Io2 => Saved_Io2);

   --  The io_forget_history statement (writer only).  C, from statement.go:
   --
   --    o_io0 = io0;  o_io1 = io1;  io0 = iop;  io1 = iop;
   --    o_buffer = *buffer;  wi = meta.wi;
   --    data.ptr += wi;  data.len -= wi;
   --    meta.ri = 0;  meta.wi = 0;  meta.pos = sat_add (meta.pos, wi);
   --    ... body ...
   --    *buffer = o_buffer;  meta.wi = iop - data.ptr;
   --    io0 = o_io0;  io1 = o_io1;
   --
   --  Begin_Forget_History does the first half: history and undo now start
   --  at the cursor (History_Length is 0, marks count from here), M
   --  becomes the meta of the re-based buffer and W.Pos follows M.Pos, so
   --  that Position (W) is, as in C, the new meta.pos plus the bytes
   --  written since.  End_Forget_History restores the saved meta with the
   --  current cursor as write index, and the saved Io0, Io1 and Pos.
   --
   --  Note that C re-bases the buffer at the meta's write index as last
   --  saved (Forgotten_Base), which is the cursor only if Save (M, W) was
   --  called just before.  This package reproduces that as is.
   type Forget_State is record
      Meta : Buffer_Meta;
      Io0  : First_Offset := 0;
      Io1  : First_Offset := 0;
   end record
   with Predicate => Io0 <= Io1;

   --  Where the re-based buffer starts in Data.
   function Forgotten_Base (Saved : Forget_State) return First_Offset is
     (Saved.Meta.Wi);

   procedure Begin_Forget_History
     (M     : in out Buffer_Meta;
      W     : in out Writer;
      Saved : out Forget_State)
   with
     Post => Saved = (Meta => M'Old, Io0 => W'Old.Io0, Io1 => W'Old.Io1)
       and then M = (Wi     => 0,
                     Ri     => 0,
                     Pos    => Ints.Sat_Add_U64 (M'Old.Pos, U64 (M'Old.Wi)),
                     Closed => M'Old.Closed)
       and then W = (W'Old with delta
                       Io0 => W'Old.Iop, Io1 => W'Old.Iop, Pos => M.Pos);

   procedure End_Forget_History
     (M     : out Buffer_Meta;
      W     : in out Writer;
      Saved : Forget_State)
   with
     Pre  => Saved.Meta.Ri <= W.Iop and then Saved.Io1 <= W.Iop,
     Post => M = (Saved.Meta with delta Wi => W.Iop)
       and then W = (W'Old with delta
                       Io0 => Saved.Io0, Io1 => Saved.Io1, Pos => Saved.Meta.Pos);

   --  Save and Reload around a callee inside an io_forget_history body,
   --  where M describes the re-based buffer: its write index counts from
   --  Forgotten_Base (Saved), and the callee is given
   --  Data (Data'First + Forgotten_Base (Saved) .. Data'First + W.Io2 - 1).
   --  C: meta.wi = iop - data.ptr and iop = data.ptr + meta.wi, with the
   --  moved data.ptr.
   procedure Save_Forgotten
     (M : in out Buffer_Meta; W : Writer; Saved : Forget_State)
   with
     Pre  => Forgotten_Base (Saved) <= W.Iop and then M.Ri = 0,
     Post => M = (M'Old with delta Wi => W.Iop - Forgotten_Base (Saved));

   procedure Reload_Forgotten
     (W : in out Writer; M : Buffer_Meta; Saved : Forget_State)
   with
     Pre  => W.Io1 - Forgotten_Base (Saved) <= M.Wi
       and then M.Wi <= W.Io2 - Forgotten_Base (Saved),
     Post => W = (W'Old with delta Iop => Forgotten_Base (Saved) + M.Wi);

   --  Writes: V goes to the cursor, which advances by the width.  Nothing
   --  else in Data changes.  The 24, 40, 48 and 56 bit forms write the low
   --  bits of V.  Write_U8_Fast also serves write_u8?() once Length (W) is
   --  known to be non-zero.

   procedure Write_U8_Fast (Data : in out Bytes; W : in out Writer; V : U8) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 1,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 1)
       and then Endian.Peek_U8 (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 1);

   procedure Write_U16BE_Fast (Data : in out Bytes; W : in out Writer; V : U16) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 2,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 2)
       and then Endian.Peek_U16BE (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 2);

   procedure Write_U16LE_Fast (Data : in out Bytes; W : in out Writer; V : U16) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 2,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 2)
       and then Endian.Peek_U16LE (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 2);

   procedure Write_U24BE_Fast (Data : in out Bytes; W : in out Writer; V : U32) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 3,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 3)
       and then Endian.Peek_U24BE (Data, Data'First + W'Old.Iop) = (V and 16#FF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 3);

   procedure Write_U24LE_Fast (Data : in out Bytes; W : in out Writer; V : U32) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 3,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 3)
       and then Endian.Peek_U24LE (Data, Data'First + W'Old.Iop) = (V and 16#FF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 3);

   procedure Write_U32BE_Fast (Data : in out Bytes; W : in out Writer; V : U32) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 4,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 4)
       and then Endian.Peek_U32BE (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 4);

   procedure Write_U32LE_Fast (Data : in out Bytes; W : in out Writer; V : U32) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 4,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 4)
       and then Endian.Peek_U32LE (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 4);

   procedure Write_U40BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 5,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 5)
       and then Endian.Peek_U40BE (Data, Data'First + W'Old.Iop) = (V and 16#FF_FFFF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 5);

   procedure Write_U40LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 5,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 5)
       and then Endian.Peek_U40LE (Data, Data'First + W'Old.Iop) = (V and 16#FF_FFFF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 5);

   procedure Write_U48BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 6,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 6)
       and then Endian.Peek_U48BE (Data, Data'First + W'Old.Iop) = (V and 16#FFFF_FFFF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 6);

   procedure Write_U48LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 6,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 6)
       and then Endian.Peek_U48LE (Data, Data'First + W'Old.Iop) = (V and 16#FFFF_FFFF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 6);

   procedure Write_U56BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 7,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 7)
       and then Endian.Peek_U56BE (Data, Data'First + W'Old.Iop) = (V and 16#FF_FFFF_FFFF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 7);

   procedure Write_U56LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 7,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 7)
       and then Endian.Peek_U56LE (Data, Data'First + W'Old.Iop) = (V and 16#FF_FFFF_FFFF_FFFF#)
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 7);

   procedure Write_U64BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 8,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 8)
       and then Endian.Peek_U64BE (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 8);

   procedure Write_U64LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) with
     Inline_Always,
     Pre  => Valid (Data, W) and then Length (W) >= 8,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 8)
       and then Endian.Peek_U64LE (Data, Data'First + W'Old.Iop) = V
       and then Endian.Same_Outside (Data'Old, Data, Data'First + W'Old.Iop, 8);
   --  C: wuffs_private_impl__io_writer__copy_from_slice.  Copies the first
   --  N bytes of Src to the cursor and advances it by N, the smaller of
   --  Src'Length and Length (W).
   --
   --  DISJOINT ONLY: Data and Src must not share any element.  If they are
   --  parts of one array use Copy_From_Slice_Within.
   procedure Copy_From_Slice
     (Data : in out Bytes;
      W    : in out Writer;
      Src  : Bytes;
      N    : out U64)
   with
     Pre  => Valid (Data, W),
     Post => Offset (N) = Offset'Min (Src'Length, W'Old.Io2 - W'Old.Iop)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then (for all J in Data'Range =>
                   (if J - Data'First >= W'Old.Iop and then J - Data'First < W.Iop
                    then Data (J) = Src (Src'First + (J - Data'First - W'Old.Iop))
                    else Data (J) = Data'Old (J)));

   --  C: wuffs_private_impl__io_writer__limited_copy_u32_from_slice.  As
   --  Copy_From_Slice, but at most Up_To bytes.
   --
   --  DISJOINT ONLY: Data and Src must not share any element.  If they are
   --  parts of one array use Limited_Copy_U32_From_Slice_Within.
   procedure Limited_Copy_U32_From_Slice
     (Data  : in out Bytes;
      W     : in out Writer;
      Up_To : U32;
      Src   : Bytes;
      N     : out U32)
   with
     Pre  => Valid (Data, W),
     Post => Offset (N) = Offset'Min
                            (Offset'Min (Offset (Up_To), Src'Length), W'Old.Io2 - W'Old.Iop)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then (for all J in Data'Range =>
                   (if J - Data'First >= W'Old.Iop and then J - Data'First < W.Iop
                    then Data (J) = Src (Src'First + (J - Data'First - W'Old.Iop))
                    else Data (J) = Data'Old (J)));

   --  C: wuffs_private_impl__io_writer__limited_copy_u32_from_reader.
   --  Moves N bytes from the reader's cursor to the writer's and advances
   --  both by N, the smallest of Up_To, Length (W) and Length (R).
   --
   --  DISJOINT ONLY: Data and Src_Data must not share any element.  If
   --  they are parts of one array use Limited_Copy_U32_From_Reader_Within.
   procedure Limited_Copy_U32_From_Reader
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Src_Data : Bytes;
      R        : in out Reader;
      N        : out U32)
   with
     Pre  => Valid (Data, W) and then Valid (Src_Data, R),
     Post => Index (N) = Index'Min
                           (Index'Min (Index (Up_To), W'Old.Io2 - W'Old.Iop),
                            R'Old.Io2 - R'Old.Iop)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then R = (R'Old with delta Iop => R'Old.Iop + Index (N))
       and then (for all J in Data'Range =>
                   (if J - Data'First >= W'Old.Iop and then J - Data'First < W.Iop
                    then Data (J) =
                           Src_Data (Src_Data'First + R'Old.Iop + (J - Data'First - W'Old.Iop))
                    else Data (J) = Data'Old (J)));

   -----------------------------------
   -- Copies within one array        --
   -----------------------------------

   --  The same-array forms of the four copies above, for operands that are
   --  parts of one array Data.  All have memmove semantics: the N bytes
   --  that arrive are the source bytes from before the call, whatever the
   --  overlap.  Counts, cursor movement and N are exactly those of the
   --  disjoint forms.
   --
   --  All positions are offsets from Data'First:
   --    R_Base, W_Base   where the reader's / writer's own array starts,
   --                     so cursor offset K is Data offset Base + K;
   --    Xxx_Offset, Xxx_Length   where a slice operand lies.

   --  True if a cursor with upper bound Io2, over an array that starts at
   --  offset Base of Data, lies within Data.
   function Valid_Within
     (Data : Bytes; Base : First_Offset; Io2 : First_Offset) return Boolean
   is (Base <= Data'Length and then Io2 <= Data'Length - Base);

   --  True if the slice of Length elements at offset Start lies within
   --  Data.  (Start is of type Offset, not Index, only so that the sum of
   --  a base and a cursor offset can be passed without a range check; it
   --  is still a count from Data'First.)
   function Slice_Within
     (Data : Bytes; Start : Offset; Length : Element_Count) return Boolean
   is (Start >= 0 and then Length <= Data'Length and then Start <= Data'Length - Length);

   --  True if New_Data is Old_Data except that the Count elements from
   --  offset Dst_Offset are Old_Data's Count elements from Src_Offset.
   function Is_Move
     (Old_Data, New_Data : Bytes;
      Dst_Offset, Src_Offset : Offset;
      Count : Element_Count) return Boolean
   is
     (Old_Data'First = New_Data'First
      and then Old_Data'Last = New_Data'Last
      and then (for all J in New_Data'Range =>
                  (if J - New_Data'First >= Dst_Offset
                     and then J - New_Data'First - Dst_Offset < Count
                   then New_Data (J) = Old_Data (J - Dst_Offset + Src_Offset)
                   else New_Data (J) = Old_Data (J))))
   with
     Ghost,
     Pre => Slice_Within (New_Data, Dst_Offset, Count)
       and then Slice_Within (New_Data, Src_Offset, Count);

   procedure Limited_Copy_U32_To_Slice_Within
     (Data       : in out Bytes;
      R_Base     : First_Offset;
      R          : in out Reader;
      Up_To      : U32;
      Dst_Offset : First_Offset;
      Dst_Length : Element_Count;
      N          : out U32)
   with
     Pre  => Valid_Within (Data, R_Base, R.Io2)
       and then Slice_Within (Data, Dst_Offset, Dst_Length),
     Post => Index (N) = Index'Min
                           (Index'Min (Index (Up_To), Dst_Length), R'Old.Io2 - R'Old.Iop)
       and then R = (R'Old with delta Iop => R'Old.Iop + Index (N))
       and then Is_Move (Data'Old, Data, Dst_Offset, R_Base + R'Old.Iop, Index (N));

   procedure Copy_From_Slice_Within
     (Data       : in out Bytes;
      W_Base     : First_Offset;
      W          : in out Writer;
      Src_Offset : First_Offset;
      Src_Length : Element_Count;
      N          : out U64)
   with
     Pre  => Valid_Within (Data, W_Base, W.Io2)
       and then Slice_Within (Data, Src_Offset, Src_Length),
     Post => Index (N) = Index'Min (Src_Length, W'Old.Io2 - W'Old.Iop)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then Is_Move (Data'Old, Data, W_Base + W'Old.Iop, Src_Offset, Index (N));

   procedure Limited_Copy_U32_From_Slice_Within
     (Data       : in out Bytes;
      W_Base     : First_Offset;
      W          : in out Writer;
      Up_To      : U32;
      Src_Offset : First_Offset;
      Src_Length : Element_Count;
      N          : out U32)
   with
     Pre  => Valid_Within (Data, W_Base, W.Io2)
       and then Slice_Within (Data, Src_Offset, Src_Length),
     Post => Index (N) = Index'Min
                           (Index'Min (Index (Up_To), Src_Length), W'Old.Io2 - W'Old.Iop)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then Is_Move (Data'Old, Data, W_Base + W'Old.Iop, Src_Offset, Index (N));

   procedure Limited_Copy_U32_From_Reader_Within
     (Data   : in out Bytes;
      W_Base : First_Offset;
      W      : in out Writer;
      Up_To  : U32;
      R_Base : First_Offset;
      R      : in out Reader;
      N      : out U32)
   with
     Pre  => Valid_Within (Data, W_Base, W.Io2)
       and then Valid_Within (Data, R_Base, R.Io2),
     Post => Index (N) = Index'Min
                           (Index'Min (Index (Up_To), W'Old.Io2 - W'Old.Iop),
                            R'Old.Io2 - R'Old.Iop)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then R = (R'Old with delta Iop => R'Old.Iop + Index (N))
       and then Is_Move
                  (Data'Old, Data, W_Base + W'Old.Iop, R_Base + R'Old.Iop, Index (N));

   --------------------
   -- History copies --
   --------------------

   --  The LZ77 back-reference: copy bytes from Distance before the cursor
   --  to the cursor, one at a time and front to back, so that the source
   --  may run into the bytes just written (Distance < number copied
   --  repeats a pattern of Distance bytes).
   --
   --  Is_History_Copy states the result: New_Data is Old_Data except that
   --  each of the Count elements from Pos on equals the element Dist
   --  before it *in New_Data*.  Together with "everything before Pos is
   --  unchanged" that fixes every byte: by induction, New_Data (Pos + K) =
   --  Old_Data (Pos - Dist + K mod Dist).
   function Is_History_Copy
     (Old_Data, New_Data : Bytes; Pos, Count, Dist : Index) return Boolean
   is
     (Old_Data'First = New_Data'First
      and then Old_Data'Last = New_Data'Last
      and then (for all J in New_Data'Range =>
                  (if J >= Pos and then J - Pos < Count
                   then New_Data (J) = New_Data (J - Dist)
                   else New_Data (J) = Old_Data (J))))
   with
     Ghost,
     Pre => Dist >= 1 and then Pos >= Dist and then Pos - Dist >= New_Data'First;

   --  The two bytes "at the cusp" after a history copy of N bytes that
   --  started at offset Start (the cursor before the copy): the last byte
   --  of the copied history and the byte after it, as a little endian
   --  u16.  C: peek_u16le (q - 1) where q is the source pointer after the
   --  copy.
   function Cusp_At (Data : Bytes; Start : Index; N : U32; Distance : U32) return U32 is
     (U32 (Endian.Peek_U16LE
             (Data, Data'First + (Start - Index (Distance) + Index (N) - 1))))
   with
     Pre => N >= 1 and then Distance >= 1
       and then Start >= Index (Distance)
       and then Start <= Data'Length
       and then Index (N) + 1 - Index (Distance) <= Data'Length - Start;

   --  C: wuffs_private_impl__io_writer__limited_copy_u32_from_history.  No
   --  preconditions beyond Valid: copies nothing if Distance is zero or
   --  reaches back beyond the history; otherwise copies N bytes, the
   --  smaller of Up_To and Length (W).
   procedure Limited_Copy_U32_From_History
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   with
     Pre  => Valid (Data, W),
     Post => (if Distance = 0 or else History_Length (W'Old) < U64 (Distance)
              then N = 0
              else Index (N) = Index'Min (Index (Up_To), W'Old.Io2 - W'Old.Iop))
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (N))
       and then (if N = 0
                 then Data = Data'Old
                 else Is_History_Copy
                        (Data'Old, Data, Data'First + W'Old.Iop, Index (N), Index (Distance)));

   --  The preconditions of the _Fast forms are the ones documented in
   --  io-private.h, which the Wuffs compiler proves at each call site.

   function Can_Copy_From_History_Fast
     (W : Writer; Up_To : U32; Distance : U32) return Boolean
   is
     (Up_To >= 1
      and then U64 (Up_To) <= Length (W)
      and then Distance >= 1
      and then U64 (Distance) <= History_Length (W));

   --  C: wuffs_private_impl__io_writer__limited_copy_u32_from_history_fast.
   --  Copies exactly Up_To bytes; N = Up_To.
   procedure Limited_Copy_U32_From_History_Fast
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   with
     Inline,
     Pre  => Valid (Data, W) and then Can_Copy_From_History_Fast (W, Up_To, Distance),
     Post => N = Up_To
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (Up_To))
       and then Is_History_Copy
                  (Data'Old, Data, Data'First + W'Old.Iop, Index (Up_To), Index (Distance));

   --  C: ..._from_history_fast_return_cusp.  The same copy; the result is
   --  the cusp instead of the count.
   procedure Limited_Copy_U32_From_History_Fast_Return_Cusp
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Cusp     : out U32)
   with
     Inline,
     Pre  => Valid (Data, W) and then Can_Copy_From_History_Fast (W, Up_To, Distance),
     Post => Cusp <= 16#FFFF#
       and then Cusp = Cusp_At (Data, W'Old.Iop, Up_To, Distance)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (Up_To))
       and then Is_History_Copy
                  (Data'Old, Data, Data'First + W'Old.Iop, Index (Up_To), Index (Distance));

   --  The 8_Byte_Chunks forms copy whole 8 byte chunks: the number of
   --  bytes *written* is Up_To rounded up to a multiple of 8 (and 8 for
   --  0), while the cursor advances by Up_To only.  So up to 7 bytes after
   --  the new cursor are overwritten, with the continuation of the same
   --  history copy, exactly as the C code does; the caller guarantees room
   --  for them (Up_To + 8 <= Length (W)).
   function Chunked_Length (Up_To : U32) return Index is
     (if Up_To = 0 then 8 else ((Index (Up_To) + 7) / 8) * 8);

   function Can_Copy_From_History_8_Byte_Chunks_Fast
     (W : Writer; Up_To : U32; Distance : U32) return Boolean
   is
     (Up_To >= 1
      and then U64 (Up_To) + 8 <= Length (W)
      and then Distance >= 1
      and then U64 (Distance) <= History_Length (W));

   --  C: ..._from_history_8_byte_chunks_fast.  Distance >= 8; N = Up_To.
   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Fast
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   with
     Inline,
     Pre  => Valid (Data, W)
       and then Can_Copy_From_History_8_Byte_Chunks_Fast (W, Up_To, Distance)
       and then Distance >= 8,
     Post => N = Up_To
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (Up_To))
       and then Is_History_Copy
                  (Data'Old, Data, Data'First + W'Old.Iop,
                   Chunked_Length (Up_To), Index (Distance));

   --  C: ..._from_history_8_byte_chunks_fast_return_cusp.
   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Fast_Return_Cusp
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Cusp     : out U32)
   with
     Inline,
     Pre  => Valid (Data, W)
       and then Can_Copy_From_History_8_Byte_Chunks_Fast (W, Up_To, Distance)
       and then Distance >= 8,
     Post => Cusp <= 16#FFFF#
       and then Cusp = Cusp_At (Data, W'Old.Iop, Up_To, Distance)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (Up_To))
       and then Is_History_Copy
                  (Data'Old, Data, Data'First + W'Old.Iop,
                   Chunked_Length (Up_To), Index (Distance));

   --  C: ..._from_history_8_byte_chunks_distance_1_fast.  Distance = 1:
   --  the byte before the cursor is repeated; N = Up_To.
   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   with
     Inline,
     Pre  => Valid (Data, W)
       and then Can_Copy_From_History_8_Byte_Chunks_Fast (W, Up_To, Distance)
       and then Distance = 1,
     Post => N = Up_To
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (Up_To))
       and then Is_History_Copy
                  (Data'Old, Data, Data'First + W'Old.Iop, Chunked_Length (Up_To), 1);

   --  C: ..._from_history_8_byte_chunks_distance_1_fast_return_cusp.
   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast_Return_Cusp
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Cusp     : out U32)
   with
     Inline,
     Pre  => Valid (Data, W)
       and then Can_Copy_From_History_8_Byte_Chunks_Fast (W, Up_To, Distance)
       and then Distance = 1,
     Post => Cusp <= 16#FFFF#
       and then Cusp = Cusp_At (Data, W'Old.Iop, Up_To, Distance)
       and then W = (W'Old with delta Iop => W'Old.Iop + Index (Up_To))
       and then Is_History_Copy
                  (Data'Old, Data, Data'First + W'Old.Iop, Chunked_Length (Up_To), 1);

end Wuffs.Base.IO;
