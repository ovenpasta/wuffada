--  Tests Wuffs.Std.Advtest, which wuffs-ada generates from
--  internal/adagen/testdata/advtest.wuffs: adversarial coroutines.
--
--  Every public coroutine is run over pseudo-random input under several
--  schedules of how much source and how much destination room it gets at a
--  time (down to one byte of each), and one trace line "= ..." is printed
--  per run, with a hash over every call's status, buffer positions and the
--  object's state.  ada/tests/crosscheck/adv.c does the same with the C code
--  that upstream's wuffs-c generates from the same Wuffs file; test.sh
--  requires the two traces to be identical.  Keep the two files in step.
--
--  This program itself only checks that nothing raises and that every run
--  ends; the comparison with C is the test.

with Ada.Text_IO;
with Adv_Support;
with Interfaces;
with Test_Support;
with Wuffs.Base;
with Wuffs.Base.IO;
with Wuffs.Std.Advtest;

procedure Test_Adv is

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Offset;
   use type Wuffs.Status;

   package A renames Wuffs.Std.Advtest;
   package AS renames Adv_Support;
   package IO renames Wuffs.Base.IO;

   Num_Funcs : constant := 28;
   Num_Seeds : constant := 64;
   Max_Calls : constant := 3000;

   type Schedule is record
      S, D : Wuffs.Index;
   end record;

   Schedules : constant array (Positive range <>) of Schedule :=
     [(0, 0), (1, 0), (0, 1), (1, 1), (2, 3), (3, 2), (5, 1), (1, 5), (7, 7)];

   function Status_Number (S : Wuffs.Status) return Wuffs.U64;

   procedure Fill (Seed : Wuffs.U32);

   function Call
     (F        : Positive;
      Dst      : in out Wuffs.Bytes;
      Dst_Meta : in out IO.Buffer_Meta;
      Src_Meta : in out IO.Buffer_Meta) return Wuffs.Status;

   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64);

   procedure Put_Number (X : Wuffs.U64);

   procedure Put_Hex_64 (X : Wuffs.U64);

   procedure Run (F : Positive; Seed : Wuffs.U32; S : Schedule);

   procedure Interleave;

   --  The numbering of statuses that adv.c uses too.
   function Status_Number (S : Wuffs.Status) return Wuffs.U64 is
   begin
      if S = Wuffs.Ok_Status then
         return 0;
      elsif S = Wuffs.Base.Suspension_Short_Read then
         return 1;
      elsif S = Wuffs.Base.Suspension_Short_Write then
         return 2;
      elsif S = A.Error_Bad_Thing then
         return 3;
      elsif S = A.Error_Inner_Failed then
         return 4;
      elsif S = Wuffs.Base.Error_Interleaved_Coroutine_Calls then
         return 5;
      elsif S = Wuffs.Base.Error_Disabled_By_Previous_Error then
         return 6;
      elsif S = Wuffs.Base.Note_End_Of_Data then
         return 7;
      else
         return 9;
      end if;
   end Status_Number;

   procedure Fill (Seed : Wuffs.U32) is
      X : Wuffs.U32 := Seed * 2654435761 + 12345;
      B : Wuffs.U8;
   begin
      for I in Wuffs.Index range 0 .. AS.Length - 1 loop
         X := X * 1103515245 + 12345;
         B := Wuffs.U8 (Interfaces.Shift_Right (X, 16) and 16#FF#);
         if Seed mod 4 = 1 then
            B := B and 7;
         elsif Seed mod 4 = 2 then
            B := B and 15;
         elsif Seed mod 4 = 3 and then I mod 3 /= 0 then
            B := B and 3;
         end if;
         AS.Input (AS.Input_First + I) := B;
      end loop;
   end Fill;

   function Call
     (F        : Positive;
      Dst      : in out Wuffs.Bytes;
      Dst_Meta : in out IO.Buffer_Meta;
      Src_Meta : in out IO.Buffer_Meta) return Wuffs.Status
   is
      type Coroutine is access function
        (Self       : in out A.Thing;
         A_Dst      : in out Wuffs.Bytes;
         A_Dst_Meta : in out IO.Buffer_Meta;
         A_Src      : Wuffs.Bytes;
         A_Src_Meta : in out IO.Buffer_Meta;
         A_Workbuf  : in out Wuffs.Bytes) return Wuffs.Status;

      Funcs : constant array (1 .. Num_Funcs) of Coroutine :=
        [A.T1'Access, A.T2'Access, A.T3'Access, A.T4'Access, A.T5'Access, A.T6'Access,
         A.T7'Access, A.T8'Access, A.T9'Access, A.U1'Access, A.U2'Access, A.U3'Access,
         A.U4'Access, A.U5'Access, A.V1'Access, A.W1'Access, A.X1'Access, A.X2'Access,
         A.X3'Access, A.X4'Access, A.X5'Access, A.X6'Access, A.X7'Access, A.X8'Access,
         A.X9'Access, A.X10'Access, A.X11'Access, A.Y1'Access];
   begin
      return
        Funcs (F)
          (AS.Thing,
           A_Dst      => Dst,
           A_Dst_Meta => Dst_Meta,
           A_Src      => AS.Input,
           A_Src_Meta => Src_Meta,
           A_Workbuf  => AS.Workbuf);
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

   procedure Put_Hex_64 (X : Wuffs.U64) is
   begin
      Test_Support.Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (X, 32)));
      Test_Support.Put_Hex (Wuffs.U32 (X and 16#FFFF_FFFF#));
   end Put_Hex_64;

   procedure Run (F : Positive; Seed : Wuffs.U32; S : Schedule) is
      Src_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Dst_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Cap      : Wuffs.Index := (if S.D = 0 then AS.Out_Cap else S.D);
      St       : Wuffs.U64 := 0;
      Calls    : Wuffs.U64 := 0;
      H        : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
      Oks      : Natural := 0;
      Errs     : Natural := 0;
      Out_Hash : Wuffs.U32 := 16#811C_9DC5#;
      Workbuf  : Wuffs.U64 := 0;
   begin
      Fill (Seed);
      AS.Output := [others => 0];
      AS.Workbuf := [others => 0];
      A.Initialize (AS.Thing);
      Src_Meta.Wi := (if S.S = 0 then AS.Length else S.S);
      --  Neither stream starts at position zero.
      Src_Meta.Pos := 1000;
      Dst_Meta.Pos := 77;

      loop
         Src_Meta.Closed := Src_Meta.Wi = AS.Length;
         St :=
           Status_Number
             (Call
                (F,
                 AS.Output (AS.Output_First .. AS.Output_First + Cap - 1),
                 Dst_Meta,
                 Src_Meta));
         Calls := Calls + 1;
         Hash_64 (H, St);
         Hash_64 (H, Wuffs.U64 (Src_Meta.Ri));
         Hash_64 (H, Wuffs.U64 (Src_Meta.Wi));
         Hash_64 (H, Wuffs.U64 (Dst_Meta.Wi));
         Hash_64 (H, Wuffs.U64 (A.Get_Sum (AS.Thing)));
         Hash_64 (H, Wuffs.U64 (A.Get_St (AS.Thing)));

         if St = 1 then
            --  Short read: more source, unless there is none.
            exit when Src_Meta.Wi = AS.Length;
            Src_Meta.Wi := Wuffs.Index'Min (Src_Meta.Wi + S.S, AS.Length);
         elsif St = 2 then
            --  Short write: more room, unless there is none.
            exit when Cap = AS.Out_Cap;
            Cap := Wuffs.Index'Min (Cap + S.D, AS.Out_Cap);
         elsif St = 0 or else St = 7 then
            --  Complete: call it again (it starts afresh), twice.
            Oks := Oks + 1;
            exit when Oks >= 3;
         elsif St = 5 or else St = 6 then
            exit;
         else
            --  An error: call it once more, to see it refuse.
            exit when Errs > 0;
            Errs := Errs + 1;
         end if;
         exit when Calls >= Max_Calls;
      end loop;

      for I in 0 .. Dst_Meta.Wi - 1 loop
         Out_Hash := (Out_Hash xor Wuffs.U32 (AS.Output (AS.Output_First + I))) * 16#0100_0193#;
      end loop;
      for I in AS.Workbuf'Range loop
         Workbuf := Workbuf * 256 + Wuffs.U64 (AS.Workbuf (I));
      end loop;

      Ada.Text_IO.Put ("= f");
      Put_Number (Wuffs.U64 (F));
      Ada.Text_IO.Put (" seed");
      Put_Number (Wuffs.U64 (Seed));
      Ada.Text_IO.Put (" s");
      Put_Number (Wuffs.U64 (S.S));
      Ada.Text_IO.Put (" d");
      Put_Number (Wuffs.U64 (S.D));
      Ada.Text_IO.Put (" calls=");
      Put_Number (Calls);
      Ada.Text_IO.Put (" status=");
      Put_Number (St);
      Ada.Text_IO.Put (" ri=");
      Put_Number (Wuffs.U64 (Src_Meta.Ri));
      Ada.Text_IO.Put (" out=");
      Put_Number (Wuffs.U64 (Dst_Meta.Wi));
      Ada.Text_IO.Put (" sum=");
      Test_Support.Put_Hex (A.Get_Sum (AS.Thing));
      Ada.Text_IO.Put (" st=");
      Test_Support.Put_Hex (A.Get_St (AS.Thing));
      Ada.Text_IO.Put (" outhash=");
      Test_Support.Put_Hex (Out_Hash);
      Ada.Text_IO.Put (" workbuf=");
      Put_Hex_64 (Workbuf);
      Ada.Text_IO.Put (" callhash=");
      Put_Hex_64 (H);
      Ada.Text_IO.New_Line;

      Test_Support.Check (Calls < Max_Calls, "coroutine does not finish, function", F);
   end Run;

   --  Interleaved public coroutines: while t9 is suspended, t1 is refused,
   --  and that disables the object.
   procedure Interleave is
      Src_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Dst_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      St       : Wuffs.U64;

      procedure Report (N : Wuffs.U64; Value : Wuffs.U64; Want : Wuffs.U64);

      procedure Report (N : Wuffs.U64; Value : Wuffs.U64; Want : Wuffs.U64) is
      begin
         Ada.Text_IO.Put ("= interleave ");
         Put_Number (N);
         Ada.Text_IO.Put (" ");
         Put_Number (Value);
         Ada.Text_IO.New_Line;
         Test_Support.Check_U64 (Value, Want, "interleave", Integer (N));
      end Report;
   begin
      Fill (0);
      A.Initialize (AS.Thing);
      Src_Meta.Wi := 1;
      St := Status_Number (Call (9, AS.Output (5 .. 68), Dst_Meta, Src_Meta));
      Report (1, St, 1);
      St := Status_Number (Call (9, AS.Output (5 .. 68), Dst_Meta, Src_Meta));
      Report (2, St, 1);
      St := Status_Number (Call (1, AS.Output (5 .. 68), Dst_Meta, Src_Meta));
      Report (3, St, 5);
      St := Status_Number (Call (9, AS.Output (5 .. 68), Dst_Meta, Src_Meta));
      Report (4, St, 6);
      Report (5, Wuffs.U64 (A.Get_Sum (AS.Thing)), 0);
   end Interleave;

begin
   for F in 1 .. Num_Funcs loop
      for Seed in Wuffs.U32 range 0 .. Num_Seeds - 1 loop
         for S of Schedules loop
            Run (F, Seed, S);
         end loop;
      end loop;
   end loop;
   Interleave;
   Test_Support.Finish ("test_adv");
end Test_Adv;
