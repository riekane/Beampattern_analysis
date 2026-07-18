function zones = build_maze_zones(maze, opts)
%BUILD_MAZE_ZONES  Build the exhaustive Y-maze zone model used to auto-select mics.
%
%   zones = BUILD_MAZE_ZONES(maze)
%   zones = BUILD_MAZE_ZONES(maze, opts)
%
% Turns the raw Y-maze landmark coordinates into a compact "zones" struct that
% SELECT_MICS_BY_POSITION() uses to decide, for any bat (x,y), which of the
% five flight zones the bat is in and therefore which microphones to keep.
%
% -------------------------------------------------------------------------
% INPUT
%   maze - struct in the Vicon global frame (mm). Exactly the struct saved
%          inside every bat_pos.mat (bat_pos.maze); also from
%          extract_maze_structure(). Fields used (rows = points in JSON order):
%             .left_wall   3x3  [maze_enter_right; maze_y-join_right; maze_exit_right]  (-X side)
%             .right_wall  3x3  [maze_enter_left ; maze_y-join_left ; maze_exit_left ]  (+X side)
%             .start_line  2x3  [maze_enter_far-right; maze_enter_far-left]
%             .takeoff_perch 1x3 (optional, plotting only)
%
%   opts - (optional) struct to override defaults; any field may be omitted:
%             .mic_sets  struct overriding per-zone mic NUMBERS, fields:
%                        approach, inside_y, past_y, arm_purple, arm_pink
%             .mic_modes struct overriding INCLUDE/EXCLUDE per zone (same fields)
%
% OUTPUT
%   zones - struct consumed by SELECT_MICS_BY_POSITION (boundaries + mic sets).
%
% -------------------------------------------------------------------------
% THE FIVE ZONES  (see zone_scheme.png). The bat flies from the perch
% (Y ~ +1560) toward the exits (Y ~ -3220): Y DECREASES along the flight.
% EXHAUSTIVE, mutually-exclusive partition; classification order:
%
%   1 approach   : Y > start line                                 -> above the maze
%   ( below start line, using the full maze WALL polyline on each side: )
%   5 arm_pink   : X is -X of the -X wall  (outside the maze on the -X side)
%   4 arm_purple : X is +X of the +X wall  (outside the maze on the +X side)
%   2 inside_y   : between the walls, above the tips of the Y      -> the Y stem
%   3 past_y     : between the walls, below the tips of the Y      -> yellow wedge
%
% Each wall is the 3-point polyline enter -> y-join -> exit. The boundary between
% the yellow (zone 3) and each arm is, in three pieces by height (see
% wall_x_at_y in select_mics_by_position):
%   above y-join      : stem segment    maze_enter  -> maze_y-join
%   y-join .. exit    : diagonal segment maze_y-join -> maze_exit
%   below the exit    : VERTICAL at maze_exit X (boundary drops straight down)
% Everything OUTSIDE that boundary line is the arm on that side.
%
% Boundaries (all from named JSON points):
%   * start line = maze_enter_far-right -- maze_enter_far-left   (slanted, eval at bat X)
%   * tips of Y  = maze_y-join_right    -- maze_y-join_left      (slanted, eval at bat X)
%   * -X wall    = maze_enter_right -- maze_y-join_right -- maze_exit_right  (eval at bat Y)
%   * +X wall    = maze_enter_left  -- maze_y-join_left  -- maze_exit_left   (eval at bat Y)
%
% NOTE on labels: the JSON object "left wall" holds the *_right points and sits on
% the -X side; "right wall" holds the *_left points on the +X side. Everything is
% keyed off the point COORDINATES so the swapped labels don't matter. Physical
% pink arm = -X side (toward maze_exit_right); purple arm = +X side (maze_exit_left).
%
% Written for the Vicon+Avisoft beam-pattern (azimuth) pipeline, 2026.

if nargin < 1 || isempty(maze), error('build_maze_zones:noMaze','maze struct required.'); end
if nargin < 2, opts = struct(); end

LW = maze.left_wall;    % [maze_enter_right; maze_y-join_right; maze_exit_right]  (-X)
RW = maze.right_wall;   % [maze_enter_left ; maze_y-join_left ; maze_exit_left ]  (+X)
SL = maze.start_line;   % [maze_enter_far-right; maze_enter_far-left]

% ---- boundary-defining points ----
zones.start_p1  = SL(1,1:2);  zones.start_p2  = SL(2,1:2);   % start line
zones.tips_p1   = LW(2,1:2);  zones.tips_p2   = RW(2,1:2);   % maze_y-join_right / _left
zones.wallR     = LW(:,1:2);  % -X wall polyline: enter_right; y-join_right; exit_right  (pink side)
zones.wallL     = RW(:,1:2);  % +X wall polyline: enter_left ; y-join_left ; exit_left   (purple side)
zones.exit_p1   = LW(3,1:2);  zones.exit_p2   = RW(3,1:2);   % exit points (plotting)

% ---- default mic sets (mic NUMBERS) and INCLUDE/EXCLUDE modes ----
def.approach   = [1 17 4 20 32];                 mode.approach   = 'EXCLUDE';
def.inside_y   = [2 3 18 19];                     mode.inside_y   = 'INCLUDE';
def.past_y     = [1 2 3 4 5 6 15 16 17 18 19 20 21 31 32];        mode.past_y     = 'INCLUDE';
def.arm_pink   = [31 16 11 29 13 28 27];          mode.arm_pink   = 'EXCLUDE';   % -X arm
def.arm_purple = [6 21 7 5 10 24 8 2 26];         mode.arm_purple = 'EXCLUDE';   % +X arm

if isfield(opts,'mic_sets') && ~isempty(opts.mic_sets)
    fn = fieldnames(opts.mic_sets); for i=1:numel(fn), def.(fn{i})=opts.mic_sets.(fn{i}); end
end
if isfield(opts,'mic_modes') && ~isempty(opts.mic_modes)
    fn = fieldnames(opts.mic_modes); for i=1:numel(fn), mode.(fn{i})=opts.mic_modes.(fn{i}); end
end

zones.mic_sets = struct( ...
    'approach',   def.approach,   'approach_mode',   mode.approach, ...
    'inside_y',   def.inside_y,   'inside_y_mode',   mode.inside_y, ...
    'past_y',     def.past_y,     'past_y_mode',     mode.past_y, ...
    'arm_purple', def.arm_purple, 'arm_purple_mode', mode.arm_purple, ...
    'arm_pink',   def.arm_pink,   'arm_pink_mode',   mode.arm_pink);

% zone id -> DISPLAY name (ids match select_mics_by_position: 1..5).
% Internal mic_sets field keys stay valid identifiers; the map id->key is:
%   1 approach   -> 'pre-maze entrance'
%   2 inside_y   -> 'maze pre-junction'
%   3 past_y     -> 'maze past-junction'
%   4 arm_purple -> 'left arm'   (+X side, toward maze_exit_left)
%   5 arm_pink   -> 'right arm'  (-X side, toward maze_exit_right)
zones.zone_names = {'pre-maze entrance','maze pre-junction','maze past-junction','left arm','right arm'};
zones.zone_keys  = {'approach','inside_y','past_y','arm_purple','arm_pink'};
zones.maze = maze;
end
