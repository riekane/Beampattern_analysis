function out = classify_trial_outcome(traj, frame_rate, maze, seg, opts)
%CLASSIFY_TRIAL_OUTCOME  Success (landed) and first-choice side for one trial.
%
%   out = CLASSIFY_TRIAL_OUTCOME(traj, frame_rate, maze, seg)
%   out = CLASSIFY_TRIAL_OUTCOME(traj, frame_rate, maze, seg, opts)
%
% Two INDEPENDENT results (kept as separate fields on purpose):
%   * landed      - did the bat settle on the landing perch?  (success/failure)
%   * side_first  - which arm did it commit to FIRST (left/right)?  This is a
%                   choice-direction measure, NOT the endpoint: a bat can go
%                   left first and land right, or go left first and fail.
%
% Zone geometry is reused verbatim from stage 2 (build_maze_zones +
% select_mics_by_position), so "left arm" = zone 4 = +X = arm_purple and
% "right arm" = zone 5 = -X = arm_pink, exactly as the mic-selection stage.
%
% INPUT
%   traj,frame_rate,maze  as for segment_flight (traj mm, Vicon frame).
%   seg                   output of segment_flight (perch centres, takeoff/land
%                         frames, per-frame dist_lp / speed).
%   opts    (optional):
%     .success_radius_mm  distance to LP centre counting as "on the perch"
%                         (default 150; user spec = within 15 cm of the marker).
%     .v_rest_mps         at-rest speed, allows crawling (default seg.params.v_rest_mps).
%     .land_window_s      final window for the settle test (default seg.params.land_window_s).
%
% OUTPUT (struct out)
%   .landed            logical (success). true iff, over the final window, the
%                      bat is within success_radius_mm of the LP centre AND at
%                      rest, AND it actually reached the perch during the trial.
%   .end_dist_LP_mm    median distance to LP over the final window, mm.
%   .end_speed_mps     median speed over the final window, m/s.
%   .end_zone_id       zone (1..5) at the settle point.
%   .end_zone_name     display name.
%   .side_first        'left' | 'right' | '' (first arm entered after take-off).
%   .side_first_zone   4 (left) | 5 (right) | NaN.
%   .side_first_frame  frame of first arm entry (NaN if none).
%   .target_side       'left' | 'right' | '' : which arm the LANDING PERCH is on.
%   .side_first_correct logical: side_first == target_side (NaN if unknown).
%   .zones             the zones struct (for plotting).
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

if nargin < 5 || isempty(opts), opts = struct(); end
if iscell(traj), traj = cell2mat(traj); end
traj = traj(:,1:3);
F = size(traj,1);

Rsucc = local_getdef(opts,'success_radius_mm',150);
vrest = local_getdef(opts,'v_rest_mps', local_pget(seg,'v_rest_mps',0.15));
Lwin  = local_getdef(opts,'land_window_s', local_pget(seg,'land_window_s',1.0));

zones = build_maze_zones(maze);
ALL   = 1:32;                            % zone id is independent of the mic set

% ---- per-frame zone id (only need x,y) ----
zid = zeros(F,1);
for f = 1:F
    xy = traj(f,1:2);
    if any(~isfinite(xy)), zid(f) = 0; continue; end
    [~, zid(f)] = select_mics_by_position(xy, zones, ALL);
end

% ---- landed? (final-window settle test) ----
wlen = max(1, round(Lwin*frame_rate));
if isfield(seg,'last_valid'), lastv = seg.last_valid;
else, lastv = find(all(isfinite(traj),2),1,'last'); if isempty(lastv), lastv = F; end
end
if ~isnan(seg.land_frame)
    w = seg.land_frame:lastv;                 % the detected settled block
else
    w = max(1,lastv-wlen+1):lastv;            % fallback: final land_window
end
out.end_dist_LP_mm = median(seg.dist_lp_xy(w), 'omitnan');   % horizontal to landing perch
out.end_speed_mps  = median(seg.speed(w),  'omitnan');
% Landed = the bat REACHED the landing perch (XY within land_xy_mm AND Z inside
% the perch vertical range) at some tracked frame. Touchdown is often untracked,
% so we do NOT require an at-rest speed here.
out.landed = ~isnan(seg.land_frame);
out.landed_perch_id = NaN;
if isfield(seg,'land_perch_id'), out.landed_perch_id = seg.land_perch_id; end
if isfield(seg,'min_dist_lp_xy_mm'), out.min_dist_LP_xy_mm = seg.min_dist_lp_xy_mm; end

% ---- end zone (at the settle point) ----
zend = zid(lastv); if zend == 0, zz = zid(w); zz = zz(zz>0); if ~isempty(zz), zend = mode(zz); end, end
out.end_zone_id   = zend;
out.end_zone_name = local_zname(zones, zend);

% ---- first-choice side: first arm (zone 4/5) entered after take-off ----
f0 = seg.takeoff_frame; if isnan(f0), f0 = 1; end
arm_frames = find((zid==4 | zid==5) & (1:F)' >= round(f0), 1, 'first');
out.side_first = ''; out.side_first_zone = NaN; out.side_first_frame = NaN;
if ~isempty(arm_frames)
    out.side_first_frame = arm_frames;
    out.side_first_zone  = zid(arm_frames);
    out.side_first = local_side(zid(arm_frames));
else
    % fallback: sign of X relative to the wall-midline at the Y-junction height,
    % evaluated at the frame of closest approach to the landing perch.
    [~,fc] = min(seg.dist_lp_xy);
    xy = traj(fc,1:2);
    if all(isfinite(xy))
        xmidR = local_wall_x(zones.wallR, xy(2));
        xmidL = local_wall_x(zones.wallL, xy(2));
        xmid  = 0.5*(xmidR + xmidL);
        if xy(1) >= xmid, out.side_first = 'left';  out.side_first_zone = 4;
        else,             out.side_first = 'right'; out.side_first_zone = 5; end
        out.side_first_frame = fc;
    end
end

% ---- target side = which arm the landing perch sits on ----
[~, lz] = select_mics_by_position(seg.lp_xyz(1,1:2), zones, ALL);
out.target_side = local_side(lz);
if isempty(out.target_side)
    % LP centre may sit just inside the maze mouth; use nearest arm by X-side
    xmidR = local_wall_x(zones.wallR, seg.lp_xyz(1,2));
    xmidL = local_wall_x(zones.wallL, seg.lp_xyz(1,2));
    if seg.lp_xyz(1,1) >= 0.5*(xmidR+xmidL), out.target_side='left'; else out.target_side='right'; end
end

if isempty(out.side_first) || isempty(out.target_side)
    out.side_first_correct = NaN;
else
    out.side_first_correct = strcmp(out.side_first, out.target_side);
end
out.zones = zones;
end

% ================= local helpers =================
function v = local_getdef(s,f,d)
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
function v = local_pget(seg,f,d)
    if isfield(seg,'params') && isfield(seg.params,f), v = seg.params.(f); else, v = d; end
end
function s = local_side(z)
    if z==4, s='left'; elseif z==5, s='right'; else, s=''; end
end
function n = local_zname(zones,z)
    if z>=1 && z<=numel(zones.zone_names), n = zones.zone_names{z}; else, n='nan'; end
end
function x = local_wall_x(wall, y)
    yjoin = wall(2,2); yexit = wall(3,2);
    if y >= yjoin,      x = local_linx(wall(1,:),wall(2,:),y);
    elseif y >= yexit,  x = local_linx(wall(2,:),wall(3,:),y);
    else,               x = wall(3,1);
    end
end
function x = local_linx(p1,p2,y)
    if abs(p2(2)-p1(2)) < 1e-9, x = 0.5*(p1(1)+p2(1));
    else, x = p1(1) + (p2(1)-p1(1))*(y-p1(2))/(p2(2)-p1(2)); end
end
