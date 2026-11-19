--  Wuffs.Base: status constants and messages, against the status strings of
--  the upstream C library (Base_Oracle_Data.Statuses).

with Base_Oracle_Data;
with Base_Test_Support; use Base_Test_Support;
with Wuffs.Base;

procedure Test_Status is

   use Wuffs;
   use Wuffs.Base;

   All_Statuses : constant array (1 .. Num_Statuses) of Status :=
     [Note_IO_Redirect,
      Note_End_Of_Data,
      Note_Metadata_Reported,
      Suspension_Even_More_Information,
      Suspension_Mispositioned_Read,
      Suspension_Mispositioned_Write,
      Suspension_Short_Read,
      Suspension_Short_Workbuf,
      Suspension_Short_Write,
      Error_Bad_IO_Position,
      Error_Bad_Argument_Length_Too_Long,
      Error_Bad_Argument_Length_Too_Short,
      Error_Bad_Argument,
      Error_Bad_Call_Sequence,
      Error_Bad_Data,
      Error_Bad_Receiver,
      Error_Bad_Restart,
      Error_Bad_Sizeof_Receiver,
      Error_Bad_Vtable,
      Error_Bad_Workbuf_Length,
      Error_Bad_Wuffs_Version,
      Error_Cannot_Return_A_Suspension,
      Error_Disabled_By_Dst_Pixel_Format_Enable_Allowlist,
      Error_Disabled_By_Previous_Error,
      Error_Initialize_Falsely_Claimed_Already_Zeroed,
      Error_Initialize_Not_Called,
      Error_Insufficient_History,
      Error_Interleaved_Coroutine_Calls,
      Error_No_More_Information,
      Error_Not_Enough_Data,
      Error_Out_Of_Bounds,
      Error_Unsupported_Image_Dimension,
      Error_Unsupported_Method,
      Error_Unsupported_Option,
      Error_Unsupported_Pixel_Swizzler_Option,
      Error_Too_Much_Data];

   Buffer : String (1 .. Max_Message_Length);
   Small  : String (11 .. 15);
   Empty  : String (1 .. 0);
   Length : Natural;

begin
   --  Both are comparisons of constants: true or false for the whole build.
   pragma Warnings (Off, "condition is always*");
   Check (Base_Oracle_Data.Num_Statuses = Num_Statuses, "status: count");
   Check (Base_Oracle_Data.Message_Width <= Max_Message_Length, "status: max length");
   pragma Warnings (On, "condition is always*");

   for I in All_Statuses'Range loop
      declare
         S : constant Status := All_Statuses (I);
         E : Base_Oracle_Data.Status_Entry renames Base_Oracle_Data.Statuses (I);
         Expected_Category : constant Status_Category :=
           (case E.Sigil is
              when '@'    => Note,
              when '$'    => Suspension,
              when others => Error);
      begin
         Check (E.Sigil in '@' | '$' | '#', "status: sigil");
         Check (S.Category = Expected_Category, "status: category");
         --  The constant found under the name that the upstream text
         --  implies (derived by rule in oracle/statuses.py) is this one.
         Check (Base_Oracle_Data.Named (I) = S, "status: name matches upstream text");
         Check (S.Code = Status_Code (I), "status: code");
         Check (Is_Base_Status (S), "status: is base");
         Check (Message_Length (S) = E.Length, "status: message length");
         Check (Is_Error (S) = (E.Sigil = '#'), "status: is_error");
         Check (Is_Suspension (S) = (E.Sigil = '$'), "status: is_suspension");
         Check (Is_Note (S) = (E.Sigil = '@'), "status: is_note");
         Check (not Is_Ok (S), "status: not ok");
         Check (Is_Complete (S) = (E.Sigil = '@'), "status: is_complete");

         Buffer := [others => '?'];
         Get_Message (S, Buffer, Length);
         Check (Length = E.Length, "status: get length");
         Check (Buffer (1 .. Length) = E.Text (1 .. E.Length), "status: text");
         Check
           ((for all J in Length + 1 .. Buffer'Last => Buffer (J) = ' '),
            "status: padding");

         --  A buffer shorter than any message: truncated, not overrun.
         Small := [others => '?'];
         Get_Message (S, Small, Length);
         Check (Length = 5, "status: truncated length");
         Check (Small = E.Text (1 .. 5), "status: truncated text");

         Get_Message (S, Empty, Length);
         Check (Length = 0, "status: empty buffer");

         --  The same code under another category is not a base status.
         declare
            Other : constant Status :=
              (Category => (if S.Category = Error then Note else Error), Code => S.Code);
         begin
            Check (not Is_Base_Status (Other), "status: wrong category");
            Check (Message_Length (Other) = 0, "status: wrong category length");
         end;

         --  All codes are distinct.
         for J in All_Statuses'First .. I - 1 loop
            Check (All_Statuses (J) /= S, "status: distinct");
         end loop;
      end;
   end loop;

   --  Ok and foreign statuses have no base message.
   Check (not Is_Base_Status (Ok_Status), "status: ok is not base");
   Check (Message_Length (Ok_Status) = 0, "status: ok length");
   Buffer := [others => '?'];
   Get_Message (Ok_Status, Buffer, Length);
   Check (Length = 0, "status: ok get length");
   Check ((for all C of Buffer => C = ' '), "status: ok padding");
   Check (Is_Complete (Ok_Status), "status: ok is complete");

   declare
      Foreign : constant array (0 .. 2) of Status_Code :=
        [37, 16#1_0001#, Status_Code'Last];
   begin
      for Code of Foreign loop
         Check (not Is_Base_Status ((Error, Code)), "status: foreign code");
         Check (Message_Length ((Error, Code)) = 0, "status: foreign length");
      end loop;
   end;

   --  Hand-written spot checks, independent of the oracle file.
   Get_Message (Error_Bad_Data, Buffer, Length);
   Check (Buffer (1 .. Length) = "base: bad data", "status: bad data");
   Get_Message (Suspension_Short_Read, Buffer, Length);
   Check (Buffer (1 .. Length) = "base: short read", "status: short read");
   Get_Message (Note_End_Of_Data, Buffer, Length);
   Check (Buffer (1 .. Length) = "base: end of data", "status: end of data");

   Check
     (Ensure_Not_A_Suspension (Suspension_Short_Write) = Error_Cannot_Return_A_Suspension,
      "status: ensure_not_a_suspension (suspension)");
   Check
     (Ensure_Not_A_Suspension (Error_Bad_Data) = Error_Bad_Data,
      "status: ensure_not_a_suspension (error)");
   Check
     (Ensure_Not_A_Suspension (Note_End_Of_Data) = Note_End_Of_Data,
      "status: ensure_not_a_suspension (note)");
   Check
     (Ensure_Not_A_Suspension (Ok_Status) = Ok_Status,
      "status: ensure_not_a_suspension (ok)");
end Test_Status;
