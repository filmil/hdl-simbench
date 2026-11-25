--  Copyright 2026 hdl-simbench authors.
--  SPDX-License-Identifier: Apache-2.0
--
--  Linked by //toolchains/gnat. Set_Close_On_Exec reaches fcntl through
--  libgnat (the call that libgnat_glibc231 renames from fcntl64).
with Ada.Text_IO;
with GNAT.OS_Lib;

procedure Hello is
   Ok : Boolean;
begin
   GNAT.OS_Lib.Set_Close_On_Exec (GNAT.OS_Lib.Standout, False, Ok);
   if not Ok then
      Ada.Text_IO.Put_Line ("fcntl failed");
      return;
   end if;
   Ada.Text_IO.Put_Line ("hello from GNAT");
end Hello;
