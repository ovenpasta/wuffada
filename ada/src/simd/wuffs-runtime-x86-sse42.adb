--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

package body Wuffs.Runtime.X86.SSE42 with SPARK_Mode => Off is

   procedure Store_Slice128 (X : M128I; A : in out Wuffs.Bytes) is
   begin
      B_Storedqu (A (A'First)'Address, To_V16QI (X));
   end Store_Slice128;

end Wuffs.Runtime.X86.SSE42;
