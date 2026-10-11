{ pkgs, ... }:
let
  nim_1_0 = pkgs.callPackage ./overlay/nim_1_0.nix { };
  x11-nim = pkgs.fetchFromGitHub {
    owner = "nim-lang";
    repo = "x11";
    rev = "29aca5e519ebf5d833f63a6a2769e62ec7bfb83a";
    hash = "sha256-jBNsv8meDvF2ySKewbA+rF2XS+gqydZUl1xhEevD15o=";
  };
  opengl-nim = pkgs.fetchFromGitHub {
    owner = "nim-lang";
    repo = "opengl";
    rev = "8e2e098f82dc5eefd874488c37b5830233cd18f4";
    hash = "sha256-v3bMDobYQZqX0anBFIUfZx5q5/vxTHO6PDtKQlf5mgU=";
  };
in {
  packages = with pkgs; [ nim_1_0 gcc libX11 libXrandr libGL ];

  # /run/opengl-driver/lib first so libGL finds the system GPU driver
  env.LD_LIBRARY_PATH = "/run/opengl-driver/lib:" + pkgs.lib.makeLibraryPath (with pkgs; [ libX11 libXrandr libGL ]);

  # nim's cache stays inside the project
  env.XDG_CACHE_HOME = ".devenv/state/cache";

  scripts.build.exec = ''
    nim -p:${x11-nim} -p:${opengl-nim}/src --nimcache:.devenv/state/nimcache c -d:release -o:boomer src/boomer.nim
  '';
}
