function [mic_nums, zone_id, zone_name, qc] = select_mics_by_position(bat_xy, zones, all_mic_nums)
%SELECT_MICS_BY_POSITION  Auto-select the mic set for a bat position in the Y-maze.
%
%   [mic_nums, zone_id, zone_name, qc] = ...
%          SELECT_MICS_BY_POSITION(bat_xy, zones, all_mic_nums)
%
% Classifies a single bat position into one of the 5 Y-maze flight zones and
% returns the microphone NUMBERS to use for beam-pattern analysis there.
%
% INPUT
%   bat_xy       - [x y] (or [x y z]) bat position, Vicon global frame, mm.
%   zones        - struct from BUILD_MAZE_ZONES().
%   all_mic_nums - vector of mic NUMBERS present/usable this session (resolves
%                  EXCLUDE lists and drops listed mics that don't exist, e.g.
%                  NaN channels 22/23/24 or mics not built this session).
%
% OUTPUT
%   mic_nums   - row vector of selected mic NUMBERS (subset of all_mic_nums).
%   zone_id    - 1..5 (0 if bat_xy is NaN).
%   zone_name  - display name from zones.zone_names:
%                'pre-maze entrance'|'maze pre-junction'|'maze past-junction'|
%                'left arm'|'right arm'|'nan'.
%   qc         - struct with the boundary values used at this position.
%
% ZONES (exhaustive; ids match BUILD_MAZE_ZONES). Classification order, using the
% full maze WALL polyline (enter -> y-join -> exit) on each side as the boundary:
%   1 approach   : y > start line
%   ( below start line: )
%   5 arm_pink   : x is -X of the -X wall  (outside the maze, pink side)
%   4 arm_purple : x is +X of the +X wall  (outside the maze, purple side)
%   2 inside_y   : between walls, above the tips of Y  (the stem)
%   3 past_y     : between walls, below the tips of Y  (yellow wedge; sides are the
%                  maze_y-join -> maze_exit diagonals)

x = bat_xy(1); y = bat_xy(2);
qc = struct('y_start',NaN,'y_tips',NaN,'x_wallR',NaN,'x_wallL',NaN);

if isnan(x) || isnan(y)
    mic_nums = []; zone_id = 0; zone_name = 'nan'; return;
end

y_start = line_y_at_x(zones.start_p1, zones.start_p2, x);
qc.y_start = y_start;

if y > y_start
    zone_id = 1; key = 'approach';
else
    x_wallR = wall_x_at_y(zones.wallR, y);   % -X wall X at this height (stem seg / diagonal)
    x_wallL = wall_x_at_y(zones.wallL, y);   % +X wall X at this height
    qc.x_wallR = x_wallR; qc.x_wallL = x_wallL;
    if x < x_wallR
        zone_id = 5; key = 'arm_pink';
    elseif x > x_wallL
        zone_id = 4; key = 'arm_purple';
    else
        y_tips = line_y_at_x(zones.tips_p1, zones.tips_p2, x);
        qc.y_tips = y_tips;
        if y > y_tips, zone_id = 2; key = 'inside_y';
        else           zone_id = 3; key = 'past_y';
        end
    end
end
zone_name = zones.zone_names{zone_id};   % human-readable display name

% --- resolve the mic set for this zone (internal key -> mic_sets fields) ---
ms = zones.mic_sets;
switch key
    case 'approach',   listed = ms.approach;   mode = ms.approach_mode;
    case 'inside_y',   listed = ms.inside_y;   mode = ms.inside_y_mode;
    case 'past_y',     listed = ms.past_y;     mode = ms.past_y_mode;
    case 'arm_purple', listed = ms.arm_purple; mode = ms.arm_purple_mode;
    case 'arm_pink',   listed = ms.arm_pink;   mode = ms.arm_pink_mode;
end

all_mic_nums = all_mic_nums(:)';
if strcmp(mode,'EXCLUDE')
    mic_nums = setdiff(all_mic_nums, listed, 'stable');
else
    mic_nums = intersect(all_mic_nums, listed, 'stable');
end
end

% ===== helpers =====
function y = line_y_at_x(p1, p2, x)
    if abs(p2(1)-p1(1)) < 1e-9, y = 0.5*(p1(2)+p2(2));
    else, y = p1(2) + (p2(2)-p1(2))*(x-p1(1))/(p2(1)-p1(1)); end
end
function x = line_x_at_y(p1, p2, y)
    if abs(p2(2)-p1(2)) < 1e-9, x = 0.5*(p1(1)+p2(1));
    else, x = p1(1) + (p2(1)-p1(1))*(y-p1(2))/(p2(2)-p1(2)); end
end
function x = wall_x_at_y(wall, y)
% X of the zone-3/arm boundary from a 3-point wall polyline [enter; y-join; exit]
% at height y:
%   y >= y-join Y : stem segment  maze_enter -> maze_y-join
%   exit Y <= y < y-join Y : diagonal segment  maze_y-join -> maze_exit
%   y < exit Y : VERTICAL at maze_exit X (the boundary drops straight down below
%                the exit line, so below the exits the arm boundary is X = maze_exit)
    yjoin = wall(2,2); yexit = wall(3,2);
    if y >= yjoin
        x = line_x_at_y(wall(1,:), wall(2,:), y);
    elseif y >= yexit
        x = line_x_at_y(wall(2,:), wall(3,:), y);
    else
        x = wall(3,1);
    end
end
