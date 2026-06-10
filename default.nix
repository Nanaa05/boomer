with import <nixpkgs> {}; let
  nim_1_0 = callPackage ./overlay/nim_1_0.nix {};
in rec {
  boomerEnv = stdenv.mkDerivation {
    name = "boomer-env";
    buildInputs = [ stdenv
                    gcc
                    gdb
                    pkgs.pkg-config
                    nim_1_0
                    libX11
                    libXrandr
                    libXext
                    libGL
                    libGLU
                    freeglut
                  ];
    LD_LIBRARY_PATH="/run/opengl-driver/lib;${libX11}/lib/;${libGL}/lib/;${libGLU}/lib;${freeglut}/lib;${libXrandr}/lib;${libXext}/lib";
  };
}
