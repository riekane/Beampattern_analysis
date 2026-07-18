function res = run_trial_analysis(cfg)
%RUN_TRIAL_ANALYSIS  Stage 4 driver: derive per-trial + per-call metrics, append
%to the study masters, and (optionally) plot the pre-flight beam.
%
%   res = RUN_TRIAL_ANALYSIS(cfg)
%
% Consumes a FULLY-processed trial (stage 1 + stage 3 already run) and the
% position-pipeline bat_pos.mat, and produces:
%   * one row appended to  <out_root>\trial_master.csv (+ .mat)
%   * pre-flight call rows appended to <out_root>\preflight_calls.csv (+ .mat)
%   * optional QC/summary figures via plot_preflight_beam.
%
% cfg FIELDS
%   .bp_proc_file  (REQUIRED)  ..._mic_data_bp_proc.mat AFTER run_beamaim_maze
%                              (must contain proc.beam_aim_az_el_deg).
%   .bat_pos_file  (REQUIRED)  position-pipeline bat_pos.mat (traj + maze +
%                              takeoff_perch/landing_perch).
%   .out_root      stats output folder    (default 'Z:\Rie\Stats\Beampattern_analysis')
%   .bat_id/.session/.trial/.date  identifiers for the join key. If omitted they
%                              are parsed from the bat_pos file name
%                              (e.g. batA125_20260709_06_bat_pos.mat).
%   .seg_opts      opts struct for segment_flight      (default [])
%   .outcome_opts  opts struct for classify_trial_outcome (default [])
%   .plot          true|false make figures             (default false)
%   .plot_dir      where figures go (default <out_root>\plots)
%
% OUTPUT struct res: .trial_row, .preflight_calls, .seg, .outcome, .cf.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

assert(isfield(cfg,'bp_proc_file') && ~isempty(cfg.bp_proc_file),'cfg.bp_proc_file required');
assert(isfield(cfg,'bat_pos_file') && ~isempty(cfg.bat_pos_file),'cfg.bat_pos_file required');
out_root = local_getdef(cfg,'out_root','Z:\Rie\Stats\Beampattern_analysis');

% ---- load ----
bpp = load(cfg.bp_proc_file);
B   = load(cfg.bat_pos_file);
traj = B.bat_pos; if iscell(traj), traj = cell2mat(traj); end
frame_rate = double(B.frame_rate);
% Trim Vicon tail to match Avisoft (same rule as bp_proc): keep first 16 s.
vdur = local_getdef(cfg,'vicon_dur_s',16);
if isfinite(vdur)
    nkeep = round(vdur*frame_rate);
    if size(traj,1) > nkeep, traj = traj(1:nkeep,:); end
end
maze = B.maze;
n_frames = size(traj,1);

% ---- identifiers ----
keys = local_keys(cfg);

% ---- pipeline ----
seg_opts = local_getdef(cfg,'seg_opts',struct());
if ~isstruct(seg_opts), seg_opts = struct(); end
% Landing/take-off perch: prefer the position-pipeline fields lp_position /
% tp_position (what bp_proc_vicon reads), then fall back to maze.landing_perch /
% maze.takeoff_perch. Explicit cfg.seg_opts.*_xyz still wins.
% Prefer the richer perch_pos (all markers; take-off marker 1, and every landing
% perch's marker 1 -> Nx3 so multiple landing perches are handled). Fall back to
% the single lp_position/tp_position (older bat_pos files), then maze.
tp_xyz = []; lp_xyz = [];
if isfield(B,'perch_pos') && ~isempty(B.perch_pos)
    [tp_xyz, lp_xyz] = local_perch_from_perchpos(B.perch_pos);
end
if isempty(tp_xyz), tp_xyz = local_resolve_perch(B, 'tp_position', maze, 'takeoff_perch'); end
if isempty(lp_xyz), lp_xyz = local_resolve_perch(B, 'lp_position', maze, 'landing_perch'); end
if ~isfield(seg_opts,'tp_xyz') && ~isempty(tp_xyz), seg_opts.tp_xyz = tp_xyz; end
if ~isfield(seg_opts,'lp_xyz') && ~isempty(lp_xyz), seg_opts.lp_xyz = lp_xyz; end
seg     = segment_flight(traj, frame_rate, maze, seg_opts);
cf      = map_calls_to_frames(bpp, frame_rate, n_frames, seg);
outcome = classify_trial_outcome(traj, frame_rate, maze, seg, local_getdef(cfg,'outcome_opts',[]));
pc      = extract_preflight_calls(bpp, seg, cf, []);
trow    = compute_trial_metrics(keys, seg, cf, pc, outcome, frame_rate, n_frames);

% ---- stamp keys onto the pre-flight call rows and append masters ----
if height(pc) > 0
    pc.bat_id  = repmat(string(keys.bat_id),  height(pc),1);
    pc.session = repmat(string(keys.session), height(pc),1);
    pc.trial   = repmat(string(keys.trial),   height(pc),1);
    pc.date    = repmat(string(keys.date),    height(pc),1);
    pc = movevars(pc, {'bat_id','session','trial','date'}, 'Before', 'call_row');
end

append_to_master_table(trow, fullfile(out_root,'trial_master.csv'), ...
                        {'bat_id','session','trial'});
if height(pc) > 0
    append_to_master_table(pc, fullfile(out_root,'preflight_calls.csv'), ...
                        {'bat_id','session','trial','call_idx'});
end

% ---- optional figures ----
if local_getdef(cfg,'plot',false)
    pdir = local_getdef(cfg,'plot_dir', fullfile(out_root,'plots'));
    plot_preflight_beam(pc, outcome, seg, struct('save_dir',pdir, ...
        'tag', sprintf('%s_%s_%s',keys.bat_id,keys.session,keys.trial)));
    % top-down maze map + decision-axis (N-perch ready; the intuitive replacement
    % for the room-frame heatmap/rose -- see plot_beam_map).
    plot_beam_map(pc, outcome, seg, struct('save_dir',pdir, ...
        'maze',maze, 'traj',traj(:,1:2), 'mic_xy',bpp.mic_loc(:,1:2)*1000, ...
        'mic_num',local_micnums(bpp.mic_names), ...
        'tag', sprintf('%s_%s_%s',keys.bat_id,keys.session,keys.trial)));
end

res = struct('trial_row',trow,'preflight_calls',pc,'seg',seg,'outcome',outcome,'cf',cf);
fprintf('Trial %s/%s/%s: landed=%d side_first=%s (target=%s) | %d calls, %d pre-flight\n', ...
    keys.bat_id, keys.session, keys.trial, outcome.landed, ...
    local_e(outcome.side_first), local_e(outcome.target_side), numel(cf.call_idx), height(pc));
end

% ================= local helpers =================
function v = local_getdef(s,f,d)
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
function s = local_e(x), if isempty(x), s='?'; else, s=x; end, end
function keys = local_keys(cfg)
    [~,bn] = fileparts(cfg.bat_pos_file);
    bat_id=''; session=''; trial='';
    tok = regexp(bn,'^([A-Za-z0-9]+)_([0-9]{6,8})_([0-9]+)','tokens','once');
    if ~isempty(tok), bat_id=tok{1}; session=tok{2}; trial=tok{3}; end
    keys.bat_id  = local_getdef(cfg,'bat_id',  bat_id);
    keys.session = local_getdef(cfg,'session', session);
    keys.trial   = local_getdef(cfg,'trial',   trial);
    keys.date    = local_getdef(cfg,'date',    session);
    fn = fieldnames(keys);
    for i=1:numel(fn), if isnumeric(keys.(fn{i})), keys.(fn{i})=num2str(keys.(fn{i})); end, end
end

function [tp, lp] = local_perch_from_perchpos(pp)
% take-off marker 1 (1x3) + every landing perch's marker 1 stacked (Nx3), mm.
    tp = []; lp = [];
    if isfield(pp,'takeoff') && isstruct(pp.takeoff) && isfield(pp.takeoff,'marker1') ...
            && ~isempty(pp.takeoff.marker1)
        tp = pp.takeoff.marker1(1,1:3);
    end
    if isfield(pp,'landing') && ~isempty(pp.landing)
        L = pp.landing;
        for k = 1:numel(L)
            if isfield(L(k),'marker1') && ~isempty(L(k).marker1)
                lp = [lp; L(k).marker1(1,1:3)]; %#ok<AGROW>
            end
        end
    end
end

function c = local_resolve_perch(B, posfield, maze, mazefield)
% Perch centre (mm, 1x3) from the bat_pos file. Priority: B.<posfield>
% (position-pipeline lp_position/tp_position) -> maze.<mazefield>. [] if neither.
    c = [];
    if isfield(B,posfield) && ~isempty(B.(posfield)), c = B.(posfield);
    elseif isstruct(maze) && isfield(maze,mazefield) && ~isempty(maze.(mazefield)), c = maze.(mazefield);
    end
    if iscell(c), c = cell2mat(c); end
    if ~isempty(c), c = mean(c(:,1:3),1,'omitnan'); end
end

function nums = local_micnums(mic_names)
    mic_names = cellstr(mic_names);
    nums = nan(numel(mic_names),1);
    for i = 1:numel(mic_names)
        tok = regexp(mic_names{i}, '(\d+)\s*$', 'tokens', 'once');
        if ~isempty(tok), nums(i) = str2double(tok{1}); end
    end
end
