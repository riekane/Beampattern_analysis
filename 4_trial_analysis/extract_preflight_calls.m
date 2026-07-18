function pc = extract_preflight_calls(bpp, seg, cf, opts)
%EXTRACT_PREFLIGHT_CALLS  Per-call pre-flight table for one trial (analysis 1 & 1b).
%
%   pc = EXTRACT_PREFLIGHT_CALLS(bpp, seg, cf)
%   pc = EXTRACT_PREFLIGHT_CALLS(bpp, seg, cf, opts)
%
% A call is PRE-FLIGHT if it was emitted before take-off. We accept a call as
% pre-flight when EITHER
%   (a) its frame <= take-off frame (time test, from map_calls_to_frames), OR
%   (b) the bat was still within the take-off-perch region at emission
%       (position test on proc.bat_loc_at_call), which is robust even if the
%       Vicon<->Avisoft timing is a few ms off.
% Both are reported so disagreements are visible.
%
% Returns a MATLAB table, one row per pre-flight call, ready to append to the
% call-level master (see append_to_master_table / run_trial_analysis). The
% "left vs right" question (1b) is served by the raw beam az/el (for the heatmap)
% plus a goal-relative azimuth: the signed horizontal angle between the beam and
% the bat->landing-perch bearing. Positive = aimed to the bat's LEFT (+X,
% arm_purple side); negative = to the RIGHT (-X, arm_pink). NOTE the beam is a
% sonar HEAD-AIM proxy, not eye gaze.
%
% INPUT
%   bpp   loaded proc struct. Needs proc.beam_aim_az_el_deg (=> stage 3 must
%         have been run), proc.bat_loc_at_call, and beam audit fields.
%   seg   segment_flight output (perch centres, take-off frame).
%   cf    map_calls_to_frames output (row-for-row with proc.* call arrays).
%   opts  (optional):
%     .perch_radius_mm  on-perch region for test (b) (default seg.params.perch_radius_mm)
%     .frame_margin     allow calls up to takeoff_frame+margin as pre-flight
%                       (default 0)
%
% OUTPUT: table pc with variables
%   call_row, call_idx, frame, t_s, time_before_takeoff_s, speed_at_call_mps,
%   on_perch, preflight_time, preflight_pos, is_preflight,
%   beam_az_deg, beam_el_deg, beam_sigma_deg, beam_method, beam_zone_id,
%   az_goal_rel_deg, dist_bat_to_LP_mm, batx_mm, baty_mm, batz_mm
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

if nargin < 4 || isempty(opts), opts = struct(); end
proc = bpp.proc;
assert(isfield(proc,'beam_aim_az_el_deg'), ['proc.beam_aim_az_el_deg missing: ' ...
    'run stage 3 (run_beamaim_maze) on this file before stage 4.']);

nC   = numel(cf.call_idx);
Rp   = local_getdef(opts,'perch_xy_mm', 300);   % XY radius counting as on the take-off perch
marg = local_getdef(opts,'frame_margin',0);

bat_m  = proc.bat_loc_at_call;                 % nC x 3, metres, Vicon frame
bat_mm = bat_m * 1000;
az     = proc.beam_aim_az_el_deg(:,1);
el     = proc.beam_aim_az_el_deg(:,2);
sig    = local_col(proc,'beam_aim_sigma_deg',nC);
meth   = local_col(proc,'beam_aim_method',nC);
zoneid = local_col(proc,'beam_zone_id',nC);

dist_lp = sqrt(sum((bat_mm - seg.lp_xyz(1,:)).^2, 2));
dist_tp = sqrt(sum((bat_mm(:,1:2) - seg.tp_xyz(1:2)).^2, 2));  % XY: bat perches on the platform ABOVE marker 1

% pre-flight tests
if ~isnan(seg.takeoff_frame)
    pf_time = cf.frame <= (seg.takeoff_frame + marg);
else
    pf_time = false(nC,1);
end
pf_pos      = dist_tp <= Rp;
is_preflight = pf_time | pf_pos;

% goal-relative azimuth (horizontal): beam bearing minus bat->LP bearing
goal_brg = atan2(seg.lp_xyz(1,2) - bat_mm(:,2), seg.lp_xyz(1,1) - bat_mm(:,1));   % rad
az_goal_rel = local_wrap180(az - rad2deg(goal_brg));

row = (1:nC)';
T = table(row, cf.call_idx, cf.frame, cf.t, cf.time_before_takeoff, cf.speed_at_call, ...
          pf_pos, pf_time, pf_pos, is_preflight, ...
          az, el, sig, meth, zoneid, az_goal_rel, dist_lp, ...
          bat_mm(:,1), bat_mm(:,2), bat_mm(:,3), ...
    'VariableNames', {'call_row','call_idx','frame','t_s','time_before_takeoff_s', ...
       'speed_at_call_mps','on_perch','preflight_time','preflight_pos','is_preflight', ...
       'beam_az_deg','beam_el_deg','beam_sigma_deg','beam_method','beam_zone_id', ...
       'az_goal_rel_deg','dist_bat_to_LP_mm','batx_mm','baty_mm','batz_mm'});

pc = T(T.is_preflight, :);
end

% ================= local helpers =================
function v = local_getdef(s,f,d)
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
function v = local_pget(seg,f,d)
    if isfield(seg,'params') && isfield(seg.params,f), v = seg.params.(f); else, v = d; end
end
function c = local_col(proc,f,nC)
    if isfield(proc,f) && ~isempty(proc.(f)), c = proc.(f)(:); c = c(1:nC);
    else, c = nan(nC,1); end
end
function a = local_wrap180(a)
    a = mod(a+180,360)-180;
end
