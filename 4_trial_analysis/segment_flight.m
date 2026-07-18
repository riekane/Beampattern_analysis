function seg = segment_flight(traj, frame_rate, maze, opts)
%SEGMENT_FLIGHT  Segment one trial: perch-sit -> take-off -> flight -> landing.
%
%   seg = SEGMENT_FLIGHT(traj, frame_rate, maze[, opts])
%
% Shared FOUNDATION for stage 4. Geometry only (no acoustics).
%
% RIG REALITY this encodes (batA125, 2026-07):
%   * The perch-sit is usually NOT Vicon-tracked (bat tracked only in flight), so
%     TAKE-OFF is detected purely from SPEED (first sustained fast frame), not
%     from leaving a perch region.
%   * TAKE-OFF perch: bat sits on a platform ~800 mm above marker 1; irrelevant
%     to a speed-based take-off, so its Z is used only as a rough location.
%   * LANDING perch: the bat can cling ANYWHERE along the vertical extent -
%     above marker 1 (pole/base, = lp_position) and below markers 2-4 (top). So
%     landing = XY within land_xy_mm of the landing perch AND Z within the range
%     [lp_z + land_z_lo_mm, lp_z + land_z_hi_mm]. Touchdown itself may be
%     untracked, so we take the FIRST tracked frame that reaches that zone.
%
% INPUT
%   traj        F x 3 bat position per Vicon frame, mm, Vicon global frame.
%   frame_rate  Hz.
%   maze        maze struct (perches fall back to maze.takeoff_perch/landing_perch).
%   opts (optional):
%     .tp_xyz/.lp_xyz   perch marker-1 positions (mm, 1x3); lp_xyz = landing base
%     .v_takeoff_mps    speed that counts as flying               (default 0.5)
%     .min_out_frames   sustained fast frames for take-off        (default 5)
%     .smooth_ms        speed smoothing window                    (default 30)
%     .land_xy_mm       horizontal radius to landing perch (+/-25 cm) (default 250)
%     .land_z_lo_mm     bottom of the landing Z-range above marker 1 (default 0)
%     .land_z_hi_mm     top of the landing Z-range above marker 1 (~markers 2-4)
%                                                                 (default 800)
%     .v_rest_mps       at-rest speed (reference only)            (default 0.15)
%     .land_window_s    final-window fallback                     (default 1.0)
%
% OUTPUT (struct seg): .t (END-aligned t(end)=0), .speed (m/s), .dist_tp (3D to
%   take-off marker), .dist_lp (3D to landing marker 1), .dist_lp_xy (horizontal),
%   .tp_xyz/.lp_xyz (markers used, mm), .takeoff_frame, .land_frame, .first_valid,
%   .last_valid, .takeoff_t/.land_t, .perch_sit_dur_s, .flight_dur_s,
%   .min_dist_lp_xy_mm, .params.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

if nargin < 4 || isempty(opts), opts = struct(); end
gp = @(f,d) local_getdef(opts,f,d);
P.smooth_ms      = gp('smooth_ms',30);
P.v_takeoff_mps  = gp('v_takeoff_mps',0.5);
P.v_rest_mps     = gp('v_rest_mps',0.15);
P.min_out_frames = gp('min_out_frames',5);
P.land_window_s  = gp('land_window_s',1.0);
P.land_xy_mm     = gp('land_xy_mm',250);
P.land_v_mps     = gp('land_v_mps',0.5);

if iscell(traj), traj = cell2mat(traj); end
traj = traj(:,1:3);
F = size(traj,1);
assert(F >= 3, 'segment_flight:shortTrack','Trajectory has < 3 frames.');

seg.t = (-(F-1):0)'/frame_rate;          % END-aligned, t(end)=0

% ---- perch marker-1 positions (mm) ----
tp = local_getdef(opts,'tp_xyz',[]);
lp = local_getdef(opts,'lp_xyz',[]);
if isempty(tp) && isfield(maze,'takeoff_perch'), tp = local_center(maze.takeoff_perch); end
if isempty(lp) && isfield(maze,'landing_perch'), lp = local_center(maze.landing_perch); end
if isempty(tp)
    error('segment_flight:noTP', ['No take-off perch. Set opts.tp_xyz, or give a ' ...
        'bat_pos with tp_position or maze.takeoff_perch. maze fields: {%s}'], ...
        strjoin(fieldnames_safe(maze), ', '));
end
if isempty(lp)
    error('segment_flight:noLP', ['No landing perch. Set opts.lp_xyz, or give a ' ...
        'bat_pos with lp_position or maze.landing_perch. maze fields: {%s}'], ...
        strjoin(fieldnames_safe(maze), ', '));
end
seg.tp_xyz = tp(1,:); seg.lp_xyz = lp;   % lp may be Nx3 (>=1 landing perch)

% ---- speed (m/s), smoothed, NaN-aware ----
step_mm   = sqrt(sum(diff(traj,1,1).^2, 2));
speed     = [NaN; step_mm] * frame_rate / 1000;
win       = max(1, round(P.smooth_ms*1e-3*frame_rate));
seg.speed = local_movmean_nan(speed, win);

% ---- distances ----
seg.dist_tp = sqrt(sum((traj - seg.tp_xyz).^2, 2));      % 3D to take-off marker (ref)
nLP = size(seg.lp_xyz,1);
dxy = inf(F, nLP);
for j = 1:nLP
    dxy(:,j) = sqrt(sum((traj(:,1:2) - seg.lp_xyz(j,1:2)).^2, 2));
end
[seg.dist_lp_xy, seg.near_lp_id] = min(dxy, [], 2);      % horizontal to NEAREST landing perch
seg.dist_lp_xy(any(isnan(traj),2)) = NaN;
seg.min_dist_lp_xy_mm = min(seg.dist_lp_xy, [], 'omitnan');

firstv = find(all(isfinite(traj),2),1,'first'); if isempty(firstv), firstv = 1; end
lastv  = find(all(isfinite(traj),2),1,'last');  if isempty(lastv),  lastv  = F; end
seg.first_valid = firstv; seg.last_valid = lastv;

% ---- take-off: SPEED-BASED ----
takeoff_frame = NaN;
for f = firstv:(lastv - P.min_out_frames + 1)
    if all(seg.speed(f:f+P.min_out_frames-1) >= P.v_takeoff_mps)
        takeoff_frame = f; break;
    end
end
if isnan(takeoff_frame)
    [mx, rel] = max(seg.speed);
    if isfinite(mx) && mx >= P.v_takeoff_mps, takeoff_frame = rel; else, takeoff_frame = firstv; end
end
seg.takeoff_frame = takeoff_frame;

% ---- landing: XY within land_xy_mm of a landing perch AND the SPEED PROFILE
% shows the bat settling (speed <= land_v_mps). We do NOT use Z: the landing
% perch top (marker 1) sits BELOW the tracked flight, and the descent/touchdown
% onto the perch is untracked, so a Z test would never fire. Rough XY location +
% deceleration is the usable signal.
at_lp = (seg.dist_lp_xy <= P.land_xy_mm) & (seg.speed <= P.land_v_mps);
at_lp(isnan(seg.dist_lp_xy) | isnan(seg.speed)) = false;
land_frame = find(at_lp, 1, 'first');
if isempty(land_frame)
    seg.land_frame = NaN; seg.land_perch_id = NaN;
else
    seg.land_frame = land_frame; seg.land_perch_id = seg.near_lp_id(land_frame);
end
land_frame = seg.land_frame;   % normalize to NaN (not []) when no landing, for the derived times below

% ---- derived times ----
seg.takeoff_t = local_frame_time(seg.t, takeoff_frame);
seg.land_t    = local_frame_time(seg.t, land_frame);
seg.perch_sit_dur_s = NaN;                                % NOTE: sit is often untracked
if ~isnan(takeoff_frame), seg.perch_sit_dur_s = seg.takeoff_t - seg.t(firstv); end
endf = land_frame; if isnan(endf), endf = lastv; end
seg.flight_dur_s = NaN;
if ~isnan(takeoff_frame), seg.flight_dur_s = seg.t(endf) - seg.takeoff_t; end

seg.params = P;
end

% ================= local helpers =================
function v = local_getdef(s,f,d)
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
function c = local_center(P)
    if isempty(P), c = []; return; end
    if iscell(P), P = cell2mat(P); end
    P = P(:,1:3); c = mean(P,1,'omitnan');
end
function y = local_movmean_nan(x, win)
    x = x(:); n = numel(x); y = nan(n,1); h = floor(win/2);
    for i = 1:n
        if isnan(x(i)), continue; end
        a = max(1,i-h); b = min(n,i+h);
        w = x(a:b); w = w(isfinite(w));
        if ~isempty(w), y(i) = mean(w); end
    end
end
function tt = local_frame_time(t, f)
    if isnan(f), tt = NaN; else, tt = t(round(f)); end
end
function fn = fieldnames_safe(x)
    if isstruct(x), fn = fieldnames(x); else, fn = {'<no maze struct>'}; end
end
