--  TEST ONLY.  A substitute for ada/src/runtime/target/wuffs-runtime-target.ads
--  that claims a 32-bit machine, so that tests on a 64-bit host run the code
--  that Wuffs decoders only use there (std/deflate's decode_huffman_fast32).
--  Selected by -XWUFFS_TEST_TARGET=force32; see ada/wuffs_gen.gpr.

package Wuffs.Runtime.Target with Preelaborate, SPARK_Mode => Off is

   function CPU_Arch_Is_32_Bit return Boolean is (True);

end Wuffs.Runtime.Target;
