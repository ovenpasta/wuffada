--  Tokens: Wuffs' token type, token buffers and the token_writer and
--  token_reader cursors, over array parameters and index values instead of
--  C pointers.  The token counterpart of Wuffs.Base.IO, in the same style.
--
--  C: wuffs/internal/cgen/base/token-public.h (wuffs_base__token,
--  wuffs_base__token_buffer, wuffs_base__token_buffer_meta and their
--  helpers), and the code that wuffs/internal/cgen/builtin.go
--  (writeBuiltinTokenWriter) and var.go (the derived variables of a
--  token_writer / token_reader argument) emit inline.
--
--  Model
--  -----
--  A token is a U64 (C: wuffs_base__token, a struct whose only member is
--  `uint64_t repr`).  A token buffer is a Wuffs.U64_Array (owned by the
--  caller, passed to every operation that touches tokens) plus a
--  Token_Buffer_Meta: wi, ri, pos, closed, as in C.  The root package's
--  U64_Array is used as it is: a token array has exactly the layout of C's
--  array of wuffs_base__token.
--
--  Bit layout of a token (token-public.h):
--
--    bits 63 .. 17   value (47 bits; signed: Value)
--      63 .. 42      value_major (22 bits; 0 means "base" tokens)
--      41 .. 17      value_minor (25 bits)
--        41 .. 38    value_base_category (for value_major = 0)
--        37 .. 17    value_base_detail (21 bits)
--      63 .. 17      for an extended token, the complement of the
--                    value_extension (bit 63 set)
--    bit  16         continued
--    bits 15 .. 0    length (in bytes of source)
--
--  Cursors.  While a Wuffs function runs, C keeps four pointers per
--  token_writer or token_reader argument (io0, io1, iop, io2).  Wuffs code
--  can do nothing with a token buffer except ask a token_writer's length()
--  and write tokens at its cursor, so only iop and io2 matter, and they
--  are the two fields of a Token_Writer or Token_Reader here.
--
--  Addressing convention: as in Wuffs.Base.IO, EVERY position is a
--  First_Offset, a count of elements from the start of the array it comes
--  with: field value K denotes Data (Data'First + K).
--
--  Protocols for generated code
--  ----------------------------
--  The same as Wuffs.Base.IO's for byte buffers.  M is the meta, W the
--  cursor, Data the token array.
--
--  Function with a token_writer argument:
--    entry:                      W := To_Writer (M, Data'Length);
--    exit, and every suspension: Save (M, W);
--
--  Passing the buffer to a callee (another Wuffs function):
--    Save (M, W);  callee (Data, M, ...);  Reload (W, M);
--
--  A token_reader argument likewise, with To_Reader.  (No Wuffs package
--  reads tokens: Wuffs has no token_reader methods.)
--
--  Method table
--  ------------
--  token_writer method                Ada (W : Token_Writer)
--  ---------------------------------  ----------------------------------
--  length()                           Length (W)
--  write_simple_token_fast!(...)      Write_Simple_Token_Fast (Data, W, ...)
--  write_extended_token_fast!(...)    Write_Extended_Token_Fast (Data, W, ...)
--
--  The writes require Length (W) >= 1, which the Wuffs compiler proves at
--  every call site from the generated code's own length() test.  Their
--  value arguments have the refinements of the Wuffs method's parameters
--  (builtin.go), which the Wuffs compiler proves too.
--
--  Overlap: no operation here takes two arrays.

with Interfaces;
with Wuffs.Base.Ints;

package Wuffs.Base.Tokens with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;

   subtype I64 is Interfaces.Integer_64;

   -----------
   -- Token --
   -----------

   --  C: WUFFS_BASE__TOKEN__*__SHIFT and friends.
   Value_Shift               : constant := 17;
   Value_Extension_Shift     : constant := 17;
   Value_Major_Shift         : constant := 42;
   Value_Minor_Shift         : constant := 17;
   Value_Base_Category_Shift : constant := 38;
   Value_Base_Detail_Shift   : constant := 17;
   Continued_Shift           : constant := 16;
   Length_Shift              : constant := 0;
   Value_Extension_Num_Bits  : constant := 46;
   Length_Max_Incl           : constant := 16#FFFF#;

   --  The two's complement reading of X (C: a cast from uint64_t to
   --  int64_t).
   function To_Signed (X : U64) return I64 is
     (if X < 2 ** 63 then I64 (X) else -I64 (not X) - 1)
   with Post => (if X < 2 ** 63 then To_Signed'Result >= 0 else To_Signed'Result < 0);

   --  C's arithmetic right shift of a signed 64-bit value: (int64_t)X >> N.
   function Shift_Right_Signed (X : U64; N : Natural) return I64 is
     (To_Signed (Interfaces.Shift_Right_Arithmetic (X, N)))
   with Pre => N <= 63;

   --  C: wuffs_base__token__value.
   function Value (T : U64) return I64 is (Shift_Right_Signed (T, Value_Shift));

   --  C: wuffs_base__token__value_extension.
   function Value_Extension (T : U64) return I64 is
     (Shift_Right_Signed (not T, Value_Extension_Shift));

   --  C: wuffs_base__token__value_major.
   function Value_Major (T : U64) return I64 is (Shift_Right_Signed (T, Value_Major_Shift));

   --  C: wuffs_base__token__value_base_category.
   function Value_Base_Category (T : U64) return I64 is
     (Shift_Right_Signed (T, Value_Base_Category_Shift));

   --  C: wuffs_base__token__value_minor.
   function Value_Minor (T : U64) return U64 is
     (Interfaces.Shift_Right (T, Value_Minor_Shift) and 16#1FF_FFFF#);

   --  C: wuffs_base__token__value_base_detail.
   function Value_Base_Detail (T : U64) return U64 is
     (Interfaces.Shift_Right (T, Value_Base_Detail_Shift) and 16#1F_FFFF#);

   --  C: wuffs_base__token__value_base_detail__sign_extended.
   function Value_Base_Detail_Sign_Extended (T : U64) return I64 is
     (Shift_Right_Signed (Interfaces.Shift_Left (T, 43 - Value_Base_Detail_Shift), 43));

   --  C: wuffs_base__token__continued.
   function Continued (T : U64) return Boolean is ((T and 16#1_0000#) /= 0);

   --  C: wuffs_base__token__length.
   function Length (T : U64) return U64 is
     (Interfaces.Shift_Right (T, Length_Shift) and 16#FFFF#);

   --  The refinements of the arguments of Wuffs' write_simple_token_fast!
   --  and write_extended_token_fast! (wuffs/lang/builtin/builtin.go).
   subtype Value_Major_Arg     is U32 range 0 .. 16#1F_FFFF#;
   subtype Value_Minor_Arg     is U32 range 0 .. 16#1FF_FFFF#;
   subtype Continued_Arg       is U32 range 0 .. 1;
   subtype Length_Arg          is U32 range 0 .. 16#FFFF#;
   subtype Value_Extension_Arg is U64 range 0 .. 16#3FFF_FFFF_FFFF#;

   --  The token that write_simple_token_fast! writes: C,
   --  writeBuiltinTokenWriter, the expression
   --    (major << VALUE_MAJOR__SHIFT) | (minor << VALUE_MINOR__SHIFT) |
   --    (continued << CONTINUED__SHIFT) | (length << LENGTH__SHIFT).
   function Make_Simple_Token
     (Value_Major : Value_Major_Arg;
      Value_Minor : Value_Minor_Arg;
      Continued   : Continued_Arg;
      Length      : Length_Arg) return U64
   is
     (Interfaces.Shift_Left (U64 (Value_Major), Value_Major_Shift)
      or Interfaces.Shift_Left (U64 (Value_Minor), Value_Minor_Shift)
      or Interfaces.Shift_Left (U64 (Continued), Continued_Shift)
      or Interfaces.Shift_Left (U64 (Length), Length_Shift))
   with
     Post => Tokens.Length (Make_Simple_Token'Result) = U64 (Length)
       and then Tokens.Continued (Make_Simple_Token'Result) = (Continued = 1)
       and then Tokens.Value_Minor (Make_Simple_Token'Result) = U64 (Value_Minor)
       and then Tokens.Value_Major (Make_Simple_Token'Result) = I64 (Value_Major);

   --  The token that write_extended_token_fast! writes: C,
   --  writeBuiltinTokenWriter, the expression
   --    (~extension << VALUE_EXTENSION__SHIFT) |
   --    (continued << CONTINUED__SHIFT) | (length << LENGTH__SHIFT).
   function Make_Extended_Token
     (Value_Extension : Value_Extension_Arg;
      Continued       : Continued_Arg;
      Length          : Length_Arg) return U64
   is
     (Interfaces.Shift_Left (not Value_Extension, Value_Extension_Shift)
      or Interfaces.Shift_Left (U64 (Continued), Continued_Shift)
      or Interfaces.Shift_Left (U64 (Length), Length_Shift))
   with
     Post => Tokens.Length (Make_Extended_Token'Result) = U64 (Length)
       and then Tokens.Continued (Make_Extended_Token'Result) = (Continued = 1)
       and then Tokens.Value_Extension (Make_Extended_Token'Result) = I64 (Value_Extension)
       and then Tokens.Value_Major (Make_Extended_Token'Result) < 0;

   -----------------------
   -- Token_Buffer_Meta --
   -----------------------

   --  C: wuffs_base__token_buffer_meta.  Data (Data'First + Ri ..
   --  Data'First + Wi - 1) has been written and not yet read.
   type Token_Buffer_Meta is record
      Wi     : Index   := 0;      --  write index, counted from Data'First
      Ri     : Index   := 0;      --  read index, counted from Data'First
      Pos    : U64     := 0;      --  token position of Data'First
      Closed : Boolean := False;  --  no further writes are expected
   end record
   with Predicate => Ri <= Wi;

   --  C: wuffs_base__token_buffer__is_valid (for a non-null pointer).
   function Is_Valid (Data : U64_Array; M : Token_Buffer_Meta) return Boolean is
     (M.Wi <= Data'Length);

   --  C: wuffs_base__empty_token_buffer_meta.
   Empty_Meta : constant Token_Buffer_Meta := (Wi => 0, Ri => 0, Pos => 0, Closed => False);

   --  C: wuffs_base__slice_token__reader and __writer (the meta part).
   function Reader_Meta (Data_Length : Index; Closed : Boolean) return Token_Buffer_Meta is
     (Wi => Data_Length, Ri => 0, Pos => 0, Closed => Closed);

   function Writer_Meta return Token_Buffer_Meta is (Empty_Meta);

   --  C: wuffs_base__token_buffer__reader_length, __reader_token_position,
   --  __writer_length, __writer_token_position.
   function Reader_Length (M : Token_Buffer_Meta) return U64 is (U64 (M.Wi - M.Ri));

   function Reader_Token_Position (M : Token_Buffer_Meta) return U64 is
     (Ints.Sat_Add_U64 (M.Pos, U64 (M.Ri)));

   --  (Zero if M does not describe Data, where C would wrap around.)
   function Writer_Length (Data : U64_Array; M : Token_Buffer_Meta) return U64 is
     (if Is_Valid (Data, M) then U64 (Data'Length - M.Wi) else 0);

   function Writer_Token_Position (M : Token_Buffer_Meta) return U64 is
     (Ints.Sat_Add_U64 (M.Pos, U64 (M.Wi)));

   --  C: wuffs_base__token_buffer__compact_retaining.  Moves the unread
   --  tokens, preceded by up to History_Retain_Length already-read tokens,
   --  to the start of Data, and adjusts M.  N is the distance moved: the
   --  number of tokens dropped from the front (C's return value).
   --
   --  These two are for the caller of a token decoder, not for generated
   --  code, so they take any meta: one that does not describe Data (a
   --  write index beyond it) is left as it is, with N = 0, where C's
   --  behaviour is undefined.
   procedure Compact_Retaining
     (Data                  : in out U64_Array;
      M                     : in out Token_Buffer_Meta;
      History_Retain_Length : U64;
      N                     : out Index)
   with
     Post => (if not Is_Valid (Data, M'Old)
              then N = 0 and then M = M'Old and then Data = Data'Old
              else Is_Valid (Data, M)
       and then U64 (M.Ri) = Ints.Min_U64 (U64 (M'Old.Ri), History_Retain_Length)
       and then N = M'Old.Ri - M.Ri
       and then M.Wi = M'Old.Wi - N
       and then M.Pos = Ints.Sat_Add_U64 (M'Old.Pos, U64 (N))
       and then M.Closed = M'Old.Closed
       and then (for all J in Data'Range =>
                   (if J - Data'First < M.Wi
                    then Data (J) = Data'Old (J + N)
                    else Data (J) = Data'Old (J))));

   --  C: wuffs_base__token_buffer__compact.  Compact_Retaining with nothing
   --  retained: N is the old M.Ri and the new M.Ri is zero.
   procedure Compact (Data : in out U64_Array; M : in out Token_Buffer_Meta; N : out Index) with
     Post => (if not Is_Valid (Data, M'Old)
              then N = 0 and then M = M'Old and then Data = Data'Old
              else Is_Valid (Data, M)
       and then M.Ri = 0
       and then N = M'Old.Ri
       and then M.Wi = M'Old.Wi - N
       and then M.Pos = Ints.Sat_Add_U64 (M'Old.Pos, U64 (N))
       and then M.Closed = M'Old.Closed
       and then (for all J in Data'Range =>
                   (if J - Data'First < M.Wi
                    then Data (J) = Data'Old (J + N)
                    else Data (J) = Data'Old (J))));

   ------------------
   -- Token_Writer --
   ------------------

   type Token_Writer is record
      Iop : Index := 0;  --  next element to write
      Io2 : Index := 0;  --  one past the last writable element
   end record
   with Predicate => Iop <= Io2;

   function Valid (Data : U64_Array; W : Token_Writer) return Boolean is (W.Io2 <= Data'Length);

   --  The cursor for a function's token_writer argument, at entry.  A
   --  closed buffer accepts no tokens (C: var.go, writeInitialLoadDerivedVar).
   function To_Writer (M : Token_Buffer_Meta; Data_Length : Index) return Token_Writer is
     (Iop => M.Wi, Io2 => (if M.Closed then M.Wi else Data_Length))
   with
     Pre  => M.Wi <= Data_Length,
     Post => To_Writer'Result.Iop = M.Wi and then To_Writer'Result.Io2 <= Data_Length;

   --  Stores the cursor position back, at exit or before passing the
   --  buffer on: M.Wi := W.Iop.
   procedure Save (M : in out Token_Buffer_Meta; W : Token_Writer) with
     Pre  => M.Ri <= W.Iop,
     Post => M = (M'Old with delta Wi => W.Iop);

   --  After a callee was given (Data, M): the cursor continues where the
   --  callee stopped.  C: iop = data.ptr + meta.wi.
   procedure Reload (W : in out Token_Writer; M : Token_Buffer_Meta) with
     Pre  => M.Wi <= W.Io2,
     Post => W = (W'Old with delta Iop => M.Wi);

   --  Wuffs token_writer.length(): the number of tokens that may still be
   --  written.
   function Length (W : Token_Writer) return U64 is (U64 (W.Io2 - W.Iop));

   --  Wuffs token_writer.write_simple_token_fast!(etc): the token
   --  Make_Simple_Token (...) goes to the cursor, which advances by one.
   --  Nothing else in Data changes.
   procedure Write_Simple_Token_Fast
     (Data        : in out U64_Array;
      W           : in out Token_Writer;
      Value_Major : Value_Major_Arg;
      Value_Minor : Value_Minor_Arg;
      Continued   : Continued_Arg;
      Length      : Length_Arg)
   with
     Pre  => Valid (Data, W) and then Tokens.Length (W) >= 1,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 1)
       and then (for all J in Data'Range =>
                   (if J - Data'First = W'Old.Iop
                    then Data (J) = Make_Simple_Token (Value_Major, Value_Minor, Continued, Length)
                    else Data (J) = Data'Old (J)));

   --  Wuffs token_writer.write_extended_token_fast!(etc), likewise with
   --  Make_Extended_Token (...).
   procedure Write_Extended_Token_Fast
     (Data            : in out U64_Array;
      W               : in out Token_Writer;
      Value_Extension : Value_Extension_Arg;
      Continued       : Continued_Arg;
      Length          : Length_Arg)
   with
     Pre  => Valid (Data, W) and then Tokens.Length (W) >= 1,
     Post => W = (W'Old with delta Iop => W'Old.Iop + 1)
       and then (for all J in Data'Range =>
                   (if J - Data'First = W'Old.Iop
                    then Data (J) = Make_Extended_Token (Value_Extension, Continued, Length)
                    else Data (J) = Data'Old (J)));

   ------------------
   -- Token_Reader --
   ------------------

   --  The cursor of a token_reader argument (C: var.go derives iop =
   --  data.ptr + meta.ri and io2 = data.ptr + meta.wi).  Wuffs has no
   --  token_reader methods, so all that generated code could do with one is
   --  build it and store it back; the generator rejects token_reader
   --  arguments until a Wuffs package needs them.
   type Token_Reader is record
      Iop : Index := 0;  --  next element to read
      Io2 : Index := 0;  --  one past the last readable element
   end record
   with Predicate => Iop <= Io2;

   function Valid (Data : U64_Array; R : Token_Reader) return Boolean is (R.Io2 <= Data'Length);

   function To_Reader (M : Token_Buffer_Meta) return Token_Reader is
     (Iop => M.Ri, Io2 => M.Wi);

   procedure Save (M : in out Token_Buffer_Meta; R : Token_Reader) with
     Pre  => R.Iop <= M.Wi,
     Post => M = (M'Old with delta Ri => R.Iop);

   procedure Reload (R : in out Token_Reader; M : Token_Buffer_Meta) with
     Pre  => M.Ri <= R.Io2,
     Post => R = (R'Old with delta Iop => M.Ri);

   function Length (R : Token_Reader) return U64 is (U64 (R.Io2 - R.Iop));

end Wuffs.Base.Tokens;
