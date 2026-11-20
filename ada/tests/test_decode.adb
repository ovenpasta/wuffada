--  Tests the generated lzw, deflate, zlib and gzip decoders.
--
--  Standard input is a manifest (from ada/tests/corpus): one test case per
--  line, "FORMAT INPUT EXPECTED", where EXPECTED is a file name or "-".
--
--  Every input is decoded under several schedules.  A schedule is how much
--  source the decoder is given at a time and how much room in the
--  destination: all of it, or as little as one byte, so that the decoder
--  suspends ("short read", "short write") at every one of its suspension
--  points and is resumed.  Between calls the buffers are compacted, as a
--  real caller does.
--
--  For each run this program
--    * checks the output against EXPECTED (if given), byte for byte, and
--      that the decoder finished with an ok status; and
--    * prints a trace line "= ..." with the final status, the number of
--      calls, the byte counts, a hash of the output and a hash of every
--      call's status and buffer positions.
--  ada/tests/crosscheck/decode.c runs the same schedules on upstream's C
--  decoders and prints the same trace; test.sh requires the two traces to be
--  identical.  Keep the two files in step.
--
--  Exits with a failure status if any check fails.

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Decode_Support;
with Interfaces;
with Test_Support;
with Wuffs.Base.Ints;
with Wuffs.Base.IO;
with Wuffs.Base.Ranges;
with Wuffs.Runtime;
with Wuffs.Std.Bzip2;
with Wuffs.Std.Deflate;
with Wuffs.Std.Gzip;
with Wuffs.Std.Lzip;
with Wuffs.Std.Lzma;
with Wuffs.Std.Lzw;
with Wuffs.Std.Xz;
with Wuffs.Std.Zlib;

procedure Test_Decode is

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Offset;
   use type Wuffs.Status_Category;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;

   package DS renames Decode_Support;
   package IO renames Wuffs.Base.IO;

   type Format is (Lzw, Deflate, Zlib, Gzip, Bzip2, Lzma, Lzip, Xz);

   type Schedule is record
      Src_Chunk : Wuffs.Index;  --  0 means everything at once.
      Dst_Chunk : Wuffs.Index;
   end record;

   type Schedule_List is array (Positive range <>) of Schedule;

   Full_Schedules : constant Schedule_List :=
     [(0, 0), (1, 0), (2, 0), (3, 0), (7, 0), (31, 0), (4095, 0), (4097, 0),
      (0, 1), (0, 2), (0, 3), (0, 7), (0, 300), (0, 4097),
      (1, 1), (3, 5), (5, 3), (300, 266), (1000, 1), (7, 2_000_000)];

   --  For inputs of more than Reduced_Above bytes.
   Reduced_Schedules : constant Schedule_List :=
     [(0, 0), (4097, 0), (0, 4097), (1000, 300), (1, 0), (0, 1), (4097, 2_000_000)];

   Reduced_Above : constant := 60_000;
   Keep_History  : constant := 1_000_000;

   --  For bzip2, lzma, lzip and xz, which make no progress with a
   --  destination of a few bytes (std/lzma wants room for a whole match).  For
   --  a long input: the first and the last three.
   Roomy_Schedules : constant Schedule_List :=
     [(0, 0), (1, 0), (2, 0), (3, 0), (7, 0), (31, 2_000_000), (4095, 0), (4097, 0),
      (0, 4097), (1, 4097), (300, 4099), (1000, 65_536), (1000, 2_000_000)];

   --  The I/O buffers that the decoders see do not start at index 0 of
   --  their arrays (and not at the same index either).
   Src_First : constant := 5;
   Dst_First : constant := 1000;

   --  No run may produce more output than this.  (The corpus's largest
   --  output is about 300 KiB.)  With it, the number of calls of a run is
   --  bounded too: see Run.
   Max_Output : constant := 8 * 1024 * 1024;

   --  What a manifest line asks for besides the decoder: see the format
   --  variants in ada/tests/corpus/main.go.
   type Variant is record
      Literal_Width : Wuffs.U64 := 8;      --  lzw2 .. lzw7
      Dictionary    : Natural := 0;        --  0 none, 1 the right one, 2 a wrong one
      Multi_Member  : Boolean := False;    --  gzipmulti
   end record;

   Dictionary_Length : constant := 1000;

   Cases : Natural := 0;
   Runs  : Natural := 0;

   procedure Load (Name : String; Into : out DS.Buffer; Length : out Wuffs.Index; OK : out Boolean);

   procedure Initialize (F : Format; V : Variant);

   function Call
     (F        : Format;
      Dst      : in out Wuffs.Bytes;
      Dst_Meta : in out IO.Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta) return Wuffs.Status;

   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64);

   procedure Put_Number (X : Wuffs.U64);

   procedure Run
     (F          : Format;
      V          : Variant;
      Name       : String;
      In_Length  : Wuffs.Index;
      Has_Exp    : Boolean;
      Exp_Length : Wuffs.Index;
      S          : Schedule);

   procedure Do_Case (Line : String);

   procedure Check_Lifecycle;

   procedure Load (Name : String; Into : out DS.Buffer; Length : out Wuffs.Index; OK : out Boolean)
   is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
      Size : SIO.Count;
   begin
      Length := 0;
      OK := False;
      SIO.Open (File, SIO.In_File, Name);
      Size := SIO.Size (File);
      if Size <= DS.Capacity then
         if Size > 0 then
            declare
               subtype SEO is Ada.Streams.Stream_Element_Offset;
               Item : Ada.Streams.Stream_Element_Array (1 .. SEO (Size))
               with Import, Address => Into'Address;
               Last : Ada.Streams.Stream_Element_Offset;
            begin
               SIO.Read (File, Item, Last);
               OK := Last = Item'Last;
            end;
         else
            OK := True;
         end if;
         Length := Wuffs.Index (Size);
      end if;
      SIO.Close (File);
   exception
      when others =>
         OK := False;
   end Load;

   procedure Initialize (F : Format; V : Variant) is
      use type Wuffs.Status;
   begin
      case F is
         when Lzw =>
            Wuffs.Std.Lzw.Initialize (DS.Lzw_Decoder);
            if V.Literal_Width /= 8 then
               Test_Support.Check
                 (DS.Lzw_Decoder.Set_Quirk
                    (Wuffs.Std.Lzw.QUIRK_LITERAL_WIDTH_PLUS_ONE, V.Literal_Width + 1)
                  = Wuffs.Ok_Status,
                  "lzw set_quirk");
               Test_Support.Check_U64
                 (DS.Lzw_Decoder.Get_Quirk (Wuffs.Std.Lzw.QUIRK_LITERAL_WIDTH_PLUS_ONE),
                  V.Literal_Width + 1,
                  "lzw get_quirk");
            end if;
         when Deflate =>
            Wuffs.Std.Deflate.Initialize (DS.Deflate_Decoder);
         when Zlib =>
            Wuffs.Std.Zlib.Initialize (DS.Zlib_Decoder);
         when Gzip =>
            Wuffs.Std.Gzip.Initialize (DS.Gzip_Decoder);
         when Bzip2 =>
            Wuffs.Std.Bzip2.Initialize (DS.Bzip2_Decoder);
         when Lzma =>
            Wuffs.Std.Lzma.Initialize (DS.Lzma_Decoder);
         when Lzip =>
            Wuffs.Std.Lzip.Initialize (DS.Lzip_Decoder);
         when Xz =>
            Wuffs.Std.Xz.Initialize (DS.Xz_Decoder);
      end case;
   end Initialize;

   --  What the decoder says is the longest work buffer that it can use.
   function Wanted_Workbuf (F : Format) return Wuffs.U64
   is (case F is
         when Lzw => DS.Lzw_Decoder.Workbuf_Len.Max_Incl,
         when Deflate => DS.Deflate_Decoder.Workbuf_Len.Max_Incl,
         when Zlib => DS.Zlib_Decoder.Workbuf_Len.Max_Incl,
         when Gzip => DS.Gzip_Decoder.Workbuf_Len.Max_Incl,
         when Bzip2 => DS.Bzip2_Decoder.Workbuf_Len.Max_Incl,
         when Lzma => DS.Lzma_Decoder.Workbuf_Len.Max_Incl,
         when Lzip => DS.Lzip_Decoder.Workbuf_Len.Max_Incl,
         when Xz => DS.Xz_Decoder.Workbuf_Len.Max_Incl);

   --  One call of transform_io, through the io_transformer interface.
   function Call
     (F        : Format;
      Dst      : in out Wuffs.Bytes;
      Dst_Meta : in out IO.Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta) return Wuffs.Status
   is
      function Transform (T : in out Wuffs.Runtime.IO_Transformer'Class) return Wuffs.Status;

      function Transform (T : in out Wuffs.Runtime.IO_Transformer'Class) return Wuffs.Status is
         Wanted : constant Wuffs.U64 := T.Workbuf_Len.Max_Incl;
         --  (std/xz says how much it needs only after it has read a block
         --  header, in the middle of a call, and then fails if it does not
         --  have it: it gets everything.)
         N      : constant Wuffs.Index :=
           (if F = Xz then DS.Work_Capacity
            elsif Wanted < 1 then 1
            elsif Wanted > DS.Work_Capacity then DS.Work_Capacity
            else Wuffs.Index (Wanted));
      begin
         return
           T.Transform_Io
             (A_Dst      => Dst,
              A_Dst_Meta => Dst_Meta,
              A_Src      => Src,
              A_Src_Meta => Src_Meta,
              A_Workbuf  => DS.Workbuf (1 .. N));
      end Transform;
   begin
      case F is
         when Lzw =>
            return Transform (DS.Lzw_Decoder);
         when Deflate =>
            return Transform (DS.Deflate_Decoder);
         when Zlib =>
            return Transform (DS.Zlib_Decoder);
         when Gzip =>
            return Transform (DS.Gzip_Decoder);
         when Bzip2 =>
            return Transform (DS.Bzip2_Decoder);
         when Lzma =>
            return Transform (DS.Lzma_Decoder);
         when Lzip =>
            return Transform (DS.Lzip_Decoder);
         when Xz =>
            return Transform (DS.Xz_Decoder);
      end case;
   end Call;

   --  FNV-1a over the 8 bytes of X, least significant first.
   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64) is
      V : Wuffs.U64 := X;
   begin
      for I in 1 .. 8 loop
         H := (H xor (V and 16#FF#)) * 16#100_0000_01B3#;
         V := Interfaces.Shift_Right (V, 8);
      end loop;
   end Hash_64;

   procedure Put_Number (X : Wuffs.U64) is
      Text  : String (1 .. 20);
      First : Natural := Text'Last + 1;
      Rest  : Wuffs.U64 := X;
   begin
      loop
         First := First - 1;
         Text (First) := Character'Val (Character'Pos ('0') + Natural (Rest mod 10));
         Rest := Rest / 10;
         exit when Rest = 0;
      end loop;
      Ada.Text_IO.Put (Text (First .. Text'Last));
   end Put_Number;

   procedure Run
     (F          : Format;
      V          : Variant;
      Name       : String;
      In_Length  : Wuffs.Index;
      Has_Exp    : Boolean;
      Exp_Length : Wuffs.Index;
      S          : Schedule)
   is
      Src_Cap : constant Wuffs.Index :=
        (if S.Src_Chunk = 0 then Wuffs.Index'Max (In_Length, 1) else S.Src_Chunk);
      Dst_Cap : constant Wuffs.Index :=
        (if S.Dst_Chunk = 0 then DS.Capacity - Dst_First else S.Dst_Chunk);

      Src_Last : constant Wuffs.Index := Src_First + Src_Cap - 1;
      Dst_Last : constant Wuffs.Index := Dst_First + Dst_Cap - 1;

      Src_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Dst_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      In_Pos   : Wuffs.Index := 0;
      Out_Pos  : Wuffs.Index := 0;
      N        : Wuffs.Index;
      Status   : Wuffs.Status := Wuffs.Ok_Status;
      Calls    : Wuffs.U64 := 0;
      Out_Hash : Wuffs.U32 := 16#811C_9DC5#;
      Call_Hash : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
      --  Every call that does not end the run either consumes input, or
      --  produces output, or is followed by one that does (a suspension
      --  with nothing to show for it can only repeat once: then the source
      --  is closed or there is room).  The slack is generous.
      Max_Calls : constant Wuffs.U64 := 4 * Wuffs.U64 (In_Length) + 4 * Max_Output + 1000;
      Matches  : Boolean := True;
      Runaway  : Boolean := False;
      Added    : Boolean := False;

      use type Wuffs.Status;
   begin
      Runs := Runs + 1;
      Initialize (F, V);
      loop
         --  Give the decoder more source, after dropping what it has read.
         IO.Compact (DS.Src_Work (Src_First .. Src_Last), Src_Meta, N);
         N := Wuffs.Index'Min (Src_Cap - Src_Meta.Wi, In_Length - In_Pos);
         if N > 0 then
            DS.Src_Work (Src_First + Src_Meta.Wi .. Src_First + Src_Meta.Wi + N - 1) :=
              DS.Input (In_Pos .. In_Pos + N - 1);
            Src_Meta.Wi := Src_Meta.Wi + N;
            In_Pos := In_Pos + N;
         end if;
         Src_Meta.Closed := In_Pos = In_Length;

         Status :=
           Call
             (F,
              Dst      => DS.Dst_Work (Dst_First .. Dst_Last),
              Dst_Meta => Dst_Meta,
              Src      => DS.Src_Work (Src_First .. Src_Last),
              Src_Meta => Src_Meta);
         Calls := Calls + 1;

         Hash_64 (Call_Hash, Wuffs.Status_Category'Pos (Status.Category));
         Hash_64 (Call_Hash, Wuffs.U64 (Status.Code));
         Hash_64 (Call_Hash, Wuffs.U64 (Src_Meta.Ri));
         Hash_64 (Call_Hash, Wuffs.U64 (Src_Meta.Wi));
         Hash_64 (Call_Hash, Src_Meta.Pos);
         Hash_64 (Call_Hash, Wuffs.U64 (Dst_Meta.Wi));
         Hash_64 (Call_Hash, Dst_Meta.Pos);

         --  Take the output, and make room again.
         for I in Dst_Meta.Ri .. Dst_Meta.Wi - 1 loop
            Out_Hash := (Out_Hash xor Wuffs.U32 (DS.Dst_Work (Dst_First + I))) * 16#0100_0193#;
            if Has_Exp
              and then (Out_Pos >= Exp_Length
                        or else DS.Expected (Out_Pos) /= DS.Dst_Work (Dst_First + I))
            then
               Matches := False;
            end if;
            Out_Pos := Out_Pos + 1;
         end loop;
         Dst_Meta.Ri := Dst_Meta.Wi;
         --  A destination of Keep_History bytes or more keeps what was
         --  written (the decoder's history) until it is half full: the other
         --  schedules start every call with an empty destination.
         if not (S.Dst_Chunk >= Keep_History and then Dst_Meta.Wi <= Dst_Cap / 2) then
            IO.Compact (DS.Dst_Work (Dst_First .. Dst_Last), Dst_Meta, N);
         end if;

         if V.Dictionary /= 0
           and then not Added
           and then Status = Wuffs.Std.Zlib.Note_Dictionary_Required
         then
            --  The decoder has read the stream's header and wants the
            --  preset dictionary.  Give it one and carry on.
            Added := True;
            for I in Wuffs.Index range 0 .. Dictionary_Length - 1 loop
               DS.Dictionary (DS.Dictionary'First + I) :=
                 (if V.Dictionary = 1
                  then Wuffs.U8 ((7 * I + I / 13) mod 256)
                  else Wuffs.U8 ((3 * I + 1) mod 256));
            end loop;
            Wuffs.Std.Zlib.Add_Dictionary (DS.Zlib_Decoder, DS.Dictionary);
            Hash_64 (Call_Hash, Wuffs.U64 (DS.Zlib_Decoder.Dictionary_Id));
         elsif V.Multi_Member
           and then Status = Wuffs.Ok_Status
           and then (In_Pos < In_Length or else Src_Meta.Ri < Src_Meta.Wi)
         then
            --  The end of one gzip member, with input left: the next one,
            --  with a decoder that starts afresh and so with a destination
            --  whose stream position starts afresh too (a new decoder
            --  rejects a destination that already has history behind it,
            --  with "bad I/O position").
            Initialize (F, V);
            Dst_Meta := IO.Empty_Meta;
         else
            exit when Status.Category /= Wuffs.Suspension;
            --  It wants a longer work buffer than there is (a corrupt LZMA
            --  header can ask for 4 GiB): that is the end of this run.
            exit when Status = Wuffs.Base.Suspension_Short_Workbuf
              and then Wanted_Workbuf (F) > DS.Work_Capacity;
         end if;

         --  A decoder that does not come to an end is a failure, here and
         --  in decode.c alike.
         if Out_Pos > Max_Output or else Calls > Max_Calls then
            Runaway := True;
            exit;
         end if;
      end loop;

      Ada.Text_IO.Put ("= ");
      Ada.Text_IO.Put (Name);
      Ada.Text_IO.Put (" s");
      Put_Number (Wuffs.U64 (S.Src_Chunk));
      Ada.Text_IO.Put (" d");
      Put_Number (Wuffs.U64 (S.Dst_Chunk));
      Ada.Text_IO.Put (" calls=");
      Put_Number (Calls);
      Ada.Text_IO.Put (" status=");
      Put_Number (Wuffs.Status_Category'Pos (Status.Category));
      Ada.Text_IO.Put (":");
      Put_Number (Wuffs.U64 (Status.Code));
      Ada.Text_IO.Put (" in=");
      Put_Number (IO.Reader_Position (Src_Meta));
      Ada.Text_IO.Put (" out=");
      Put_Number (Wuffs.U64 (Out_Pos));
      Ada.Text_IO.Put (" outhash=");
      Test_Support.Put_Hex (Out_Hash);
      Ada.Text_IO.Put (" callhash=");
      Test_Support.Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (Call_Hash, 32)));
      Test_Support.Put_Hex (Wuffs.U32 (Call_Hash and 16#FFFF_FFFF#));
      Ada.Text_IO.New_Line;

      Test_Support.Check (not Runaway, "decoder does not come to an end", Integer (Runs), Name);
      if Has_Exp then
         Test_Support.Check
           (Status.Category = Wuffs.Ok, "final status is not ok", Integer (Runs), Name);
         Test_Support.Check
           (Matches and then Out_Pos = Exp_Length, "output differs", Integer (Runs), Name);
      else
         --  The trace carries the result.  Count the run as checked.
         Test_Support.Check (True, "ran");
      end if;
   end Run;

   procedure Do_Case (Line : String) is
      Sp1, Sp2   : Natural := 0;
      F          : Format;
      V          : Variant;
      In_Length  : Wuffs.Index;
      Exp_Length : Wuffs.Index := 0;
      Has_Exp    : Boolean;
      OK         : Boolean;
      Slash      : Natural;
   begin
      for I in Line'Range loop
         if Line (I) = ' ' then
            if Sp1 = 0 then
               Sp1 := I;
            elsif Sp2 = 0 then
               Sp2 := I;
            end if;
         end if;
      end loop;
      if Sp2 = 0 or else Sp2 = Line'Last then
         Test_Support.Check (False, "malformed manifest line", -1, Line);
         return;
      end if;
      declare
         Kind     : String renames Line (Line'First .. Sp1 - 1);
         In_Name  : String renames Line (Sp1 + 1 .. Sp2 - 1);
         Exp_Name : String renames Line (Sp2 + 1 .. Line'Last);
      begin
         if Kind = "lzw" then
            F := Lzw;
         elsif Kind'Length = 4
           and then Kind (Kind'First .. Kind'First + 2) = "lzw"
           and then Kind (Kind'Last) in '2' .. '7'
         then
            F := Lzw;
            V.Literal_Width := Character'Pos (Kind (Kind'Last)) - Character'Pos ('0');
         elsif Kind = "deflate" then
            F := Deflate;
         elsif Kind = "zlib" then
            F := Zlib;
         elsif Kind = "zlibdict" then
            F := Zlib;
            V.Dictionary := 1;
         elsif Kind = "zlibwrongdict" then
            F := Zlib;
            V.Dictionary := 2;
         elsif Kind = "gzip" then
            F := Gzip;
         elsif Kind = "bzip2" then
            F := Bzip2;
         elsif Kind = "lzma" then
            F := Lzma;
         elsif Kind = "lzip" then
            F := Lzip;
         elsif Kind = "xz" then
            F := Xz;
         elsif Kind = "gzipmulti" then
            F := Gzip;
            V.Multi_Member := True;
         else
            Test_Support.Check (False, "unknown format", -1, Line);
            return;
         end if;
         Load (In_Name, DS.Input, In_Length, OK);
         Test_Support.Check (OK, "cannot load", -1, In_Name);
         if not OK then
            return;
         end if;
         Has_Exp := Exp_Name /= "-";
         if Has_Exp then
            Load (Exp_Name, DS.Expected, Exp_Length, OK);
            Test_Support.Check (OK, "cannot load", -1, Exp_Name);
            if not OK then
               return;
            end if;
         end if;

         --  The trace names the input without its directory.
         Slash := In_Name'First - 1;
         for I in In_Name'Range loop
            if In_Name (I) = '/' then
               Slash := I;
            end if;
         end loop;

         Cases := Cases + 1;
         if F >= Bzip2 then
            for I in Roomy_Schedules'Range loop
               if In_Length <= Reduced_Above or else I = 1 or else I > 10 then
                  Run
                    (F, V, In_Name (Slash + 1 .. In_Name'Last), In_Length, Has_Exp, Exp_Length,
                     Roomy_Schedules (I));
               end if;
            end loop;
         elsif In_Length > Reduced_Above then
            for S of Reduced_Schedules loop
               Run (F, V, In_Name (Slash + 1 .. In_Name'Last), In_Length, Has_Exp, Exp_Length, S);
            end loop;
         else
            for S of Full_Schedules loop
               Run (F, V, In_Name (Slash + 1 .. In_Name'Last), In_Length, Has_Exp, Exp_Length, S);
            end loop;
         end if;
      end;
   end Do_Case;

   --  What a decoder does when it is misused: called before Initialize,
   --  given a buffer whose meta does not describe it, called again after
   --  that; and that Initialize makes it usable again.
   procedure Check_Lifecycle is
      use type Wuffs.Status;
      use type Wuffs.Base.Ints.Optional_U63;
      use type Wuffs.Base.Ranges.Range_II_U64;

      --  A Buffer_Meta's representation, to make invalid ones from.
      type Raw_Meta is record
         Wi     : Interfaces.Integer_64;
         Ri     : Interfaces.Integer_64;
         Pos    : Wuffs.U64;
         Closed : Wuffs.U8;
      end record
      with Convention => C;

      use type Interfaces.Integer_64;

      --  The same storage seen both ways (in effect an unchecked
      --  conversion, without a copy).
      Raw     : aliased Raw_Meta := (Wi => 0, Ri => 0, Pos => 0, Closed => 0);
      Invalid : IO.Buffer_Meta
      with Import, Address => Raw'Address;

      Raw_Metas : constant array (1 .. 5) of Raw_Meta :=
        [(Wi => 0, Ri => -1, Pos => 0, Closed => 0),
         (Wi => -5, Ri => -5, Pos => 0, Closed => 0),
         (Wi => 2, Ri => -(2 ** 62), Pos => 0, Closed => 0),
         (Wi => Interfaces.Integer_64'Last, Ri => 0, Pos => 0, Closed => 0),
         (Wi => 0, Ri => 0, Pos => 0, Closed => 2)];

      Src      : constant Wuffs.Bytes (1 .. 4) := [others => 0];
      Dst      : Wuffs.Bytes (1 .. 4) := [others => 0];
      Src_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Dst_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Bad_Meta : IO.Buffer_Meta := (Wi => 5, Ri => 0, Pos => 0, Closed => False);
      Status   : Wuffs.Status;
   begin
      for F in Format range Lzw .. Gzip loop
         --  DS.*_Decoder have not been initialized yet (this runs first).
         Status := Call (F, Dst, Dst_Meta, Src, Src_Meta);
         Test_Support.Check
           (Status = Wuffs.Base.Error_Initialize_Not_Called,
            "transform_io before Initialize",
            Format'Pos (F));

         Initialize (F, (others => <>));
         --  A write index beyond the end of the array.
         Status := Call (F, Dst, Bad_Meta, Src, Src_Meta);
         Test_Support.Check
           (Status = Wuffs.Base.Error_Bad_Argument, "transform_io with a bad dst", Format'Pos (F));
         Status := Call (F, Dst, Dst_Meta, Src, Src_Meta);
         Test_Support.Check
           (Status = Wuffs.Base.Error_Disabled_By_Previous_Error,
            "transform_io when disabled",
            Format'Pos (F));

         Initialize (F, (others => <>));
         Status := Call (F, Dst, Dst_Meta, Src, Bad_Meta);
         Test_Support.Check
           (Status = Wuffs.Base.Error_Bad_Argument, "transform_io with a bad src", Format'Pos (F));

         --  Metas whose fields are not even values of their subtypes: a
         --  negative index, an out-of-range Boolean.  Nothing but the
         --  decoder's own check stands between these and an out-of-bounds
         --  access in the release profile.
         for K in Raw_Metas'Range loop
            Initialize (F, (others => <>));
            Raw := Raw_Metas (K);
            Status := Call (F, Dst, Dst_Meta, Src, Invalid);
            Test_Support.Check
              (Status = Wuffs.Base.Error_Bad_Argument,
               "transform_io with an invalid src meta",
               K);
            Initialize (F, (others => <>));
            Raw := Raw_Metas (K);
            Status := Call (F, Dst, Invalid, Src, Src_Meta);
            Test_Support.Check
              (Status = Wuffs.Base.Error_Bad_Argument,
               "transform_io with an invalid dst meta",
               K);
         end loop;

         --  An empty, open source: the decoder wants more, and says so
         --  again when asked again.
         Initialize (F, (others => <>));
         for I in 1 .. 2 loop
            Status := Call (F, Dst, Dst_Meta, Src, Src_Meta);
            Test_Support.Check
              (Status = Wuffs.Base.Suspension_Short_Read,
               "transform_io with no input",
               Format'Pos (F));
         end loop;
         Initialize (F, (others => <>));
      end loop;

      Test_Support.Check
        (DS.Gzip_Decoder.Workbuf_Len = Wuffs.Base.Ranges.Make_Range_II_U64 (1, 1),
         "gzip workbuf_len");
      Test_Support.Check
        (DS.Lzw_Decoder.Workbuf_Len = Wuffs.Base.Ranges.Make_Range_II_U64 (0, 0),
         "lzw workbuf_len");
      Test_Support.Check
        (DS.Deflate_Decoder.Dst_History_Retain_Length
         = Wuffs.Base.Ints.Make_Optional_U63 (Has_Value => True, Value => 0),
         "deflate dst_history_retain_length");
      Test_Support.Check
        (DS.Zlib_Decoder.Set_Quirk (12345, 1) = Wuffs.Base.Error_Unsupported_Option,
         "zlib set_quirk");
      Test_Support.Check_U64 (DS.Zlib_Decoder.Get_Quirk (12345), 0, "zlib get_quirk");
      Test_Support.Check_U32 (DS.Zlib_Decoder.Dictionary_Id, 0, "zlib dictionary_id");
      Wuffs.Std.Zlib.Initialize (DS.Zlib_Decoder);
   end Check_Lifecycle;

   Line : String (1 .. 4096);
   Last : Natural;

begin
   Check_Lifecycle;
   while not Ada.Text_IO.End_Of_File loop
      Ada.Text_IO.Get_Line (Line, Last);
      if Last > 0 then
         Do_Case (Line (1 .. Last));
      end if;
   end loop;
   Ada.Text_IO.Put ("test_decode: cases:");
   Ada.Text_IO.Put (Cases'Image);
   Ada.Text_IO.Put (", runs:");
   Ada.Text_IO.Put_Line (Runs'Image);
   Test_Support.Finish ("test_decode");
end Test_Decode;
