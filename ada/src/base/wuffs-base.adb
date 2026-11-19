package body Wuffs.Base with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   subtype Message_Text is String (1 .. Max_Message_Length);
   subtype Message_Length_Type is Natural range 1 .. Max_Message_Length;

   type Entry_Type is record
      Category : Status_Category;
      Length   : Message_Length_Type;
      Text     : Message_Text;
   end record;

   subtype Base_Code is Status_Code range 1 .. Num_Statuses;

   --  Generated from the Statuses list in wuffs/lang/builtin/builtin.go
   --  (pinned commit); text padded with spaces to Max_Message_Length.
   Table : constant array (Base_Code) of Entry_Type :=
     [
       1 => (Note,      18,
             "base: I/O redirect                                                      "),
       2 => (Note,      17,
             "base: end of data                                                       "),
       3 => (Note,      23,
             "base: metadata reported                                                 "),
       4 => (Suspension, 27,
             "base: even more information                                             "),
       5 => (Suspension, 24,
             "base: mispositioned read                                                "),
       6 => (Suspension, 25,
             "base: mispositioned write                                               "),
       7 => (Suspension, 16,
             "base: short read                                                        "),
       8 => (Suspension, 19,
             "base: short workbuf                                                     "),
       9 => (Suspension, 17,
             "base: short write                                                       "),
      10 => (Error,     22,
             "base: bad I/O position                                                  "),
      11 => (Error,     36,
             "base: bad argument (length too long)                                    "),
      12 => (Error,     37,
             "base: bad argument (length too short)                                   "),
      13 => (Error,     18,
             "base: bad argument                                                      "),
      14 => (Error,     23,
             "base: bad call sequence                                                 "),
      15 => (Error,     14,
             "base: bad data                                                          "),
      16 => (Error,     18,
             "base: bad receiver                                                      "),
      17 => (Error,     17,
             "base: bad restart                                                       "),
      18 => (Error,     25,
             "base: bad sizeof receiver                                               "),
      19 => (Error,     16,
             "base: bad vtable                                                        "),
      20 => (Error,     24,
             "base: bad workbuf length                                                "),
      21 => (Error,     23,
             "base: bad wuffs version                                                 "),
      22 => (Error,     32,
             "base: cannot return a suspension                                        "),
      23 => (Error,     66,
             "base: disabled by WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST      "),
      24 => (Error,     32,
             "base: disabled by previous error                                        "),
      25 => (Error,     47,
             "base: initialize falsely claimed already zeroed                         "),
      26 => (Error,     27,
             "base: initialize not called                                             "),
      27 => (Error,     26,
             "base: insufficient history                                              "),
      28 => (Error,     33,
             "base: interleaved coroutine calls                                       "),
      29 => (Error,     25,
             "base: no more information                                               "),
      30 => (Error,     21,
             "base: not enough data                                                   "),
      31 => (Error,     19,
             "base: out of bounds                                                     "),
      32 => (Error,     33,
             "base: unsupported image dimension                                       "),
      33 => (Error,     24,
             "base: unsupported method                                                "),
      34 => (Error,     24,
             "base: unsupported option                                                "),
      35 => (Error,     39,
             "base: unsupported pixel swizzler option                                 "),
      36 => (Error,     19,
             "base: too much data                                                     ")     ];

   --------------------
   -- Is_Base_Status --
   --------------------

   function Is_Base_Status (S : Status) return Boolean is
     (S.Code in Base_Code and then Table (S.Code).Category = S.Category);

   --------------------
   -- Message_Length --
   --------------------

   function Message_Length (S : Status) return Natural is
     (if Is_Base_Status (S) then Table (S.Code).Length else 0);

   -----------------
   -- Get_Message --
   -----------------

   procedure Get_Message (S : Status; Buffer : out String; Length : out Natural) is
   begin
      Length := Integer'Min (Message_Length (S), Buffer'Length);
      Buffer := [others => ' '];
      if Length > 0 then
         Buffer (Buffer'First .. Buffer'First + (Length - 1)) :=
           Table (S.Code).Text (1 .. Length);
      end if;
   end Get_Message;

end Wuffs.Base;
