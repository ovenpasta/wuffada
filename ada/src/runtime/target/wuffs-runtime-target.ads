--  What generated code asks about the machine it runs on.  This is its own
--  package, in its own directory, so that a test build can substitute
--  another one (ada/tests/target32, selected by the WUFFS_TEST_TARGET
--  scenario variable of wuffs_gen.gpr) and so exercise the code paths that
--  Wuffs decoders only take on 32-bit machines.

package Wuffs.Runtime.Target with Preelaborate, SPARK_Mode => Off is

   --  Wuffs `base.utility.cpu_arch_is_32_bit()`.  C: sizeof (void*) == 4.
   function CPU_Arch_Is_32_Bit return Boolean is (Standard'Address_Size = 32);

end Wuffs.Runtime.Target;
