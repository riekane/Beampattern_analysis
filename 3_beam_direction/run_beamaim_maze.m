function out = run_beamaim_maze(cfg)
%RUN_BEAMAIM_MAZE  Head-aim PROXY (beam-aim direction) per call, maze-aware.
%
%   out = RUN_BEAMAIM_MAZE(cfg)
%
% Keeps the maze-aware microphone selection (build_maze_zones +
% select_mics_by_position) but replaces the crude "peak-intensity mic" direction
% with the interpolation + Gaussian-fit beam-aim estimate ported from beam_aim.m
% (see estimate_beam_direction.m).
%
%
% cfg FIELDS
%   .bp_proc_file  - processed beam file (…_mic_data_bp_proc.mat). Must contain
%                    proc.<dB field> {calls x mics}, proc.call_freq_vec,
%                    proc.bat_loc_at_call (calls x 3, m, SAME frame as mic_loc),
%                    mic_loc (mics x 3), mic_names, mic_data.*   (REQUIRED)
%   .bat_pos_file  - position-pipeline bat_pos.mat for this trial (trajectory +
%                    embedded .maze) for maze zone classification. If empty, uses
%                    a track/maze inside bp_proc_file.                (default '')
%   .freq_desired  - kHz.                                            (default 35)
%   .sync_offset_s - DEPRECATED / no longer used. Zone classification now comes
%                    from proc.bat_loc_at_call (solved in stage 1), so the
%                    Vicon<->Avisoft alignment belongs in stage 1, not here.
%                    Kept only for backward-compatible cfg structs.   (default 0)
%   .db_field      - '' to auto-pick a compensated dB field, or a name. (default '')
%   .save_back     - write results back into bp_proc_file.          (default true)
%   .est_opts      - options struct for estimate_beam_direction.m.  (default anchored)
%
% OUTPUT struct `out` (and, if save_back, saved into bp_proc_file):
%   .beam_aim_az_el_deg  calls x 2  HEAD-AIM PROXY azimuth/elevation (deg)
%   .beam_aim_sigma_deg  calls x 1  azimuth beam half-width (deg)
%   .beam_aim_method     calls x 1  1=interp, 2=peak fallback, 0=none
%   .beam_peak_az_el_deg calls x 2  loudest-mic az/el (audit / continuity)
%   .beam_zone_id        calls x 1  zone 1..5 (0=no track)
%   .beam_sel_mic_num    calls x 1  loudest selected mic NUMBER
%   .beam_n_mics_used    calls x 1  #mics that entered the estimate
% -------------------------------------------------------------------------

% ---- unpack cfg with defaults ----
assert(isfield(cfg,'bp_proc_file') && ~isempty(cfg.bp_proc_file), 'cfg.bp_proc_file is required.');
bp_proc_file  = cfg.bp_proc_file;
bat_pos_file  = getdef(cfg,'bat_pos_file','');
freq_desired  = getdef(cfg,'freq_desired',35);
sync_offset_s = getdef(cfg,'sync_offset_s',0);
db_field      = getdef(cfg,'db_field','');
save_back     = getdef(cfg,'save_back',true);
est_opts      = getdef(cfg,'est_opts', struct('method','anchored','interp_method','rb_rbf', ...
                       'min_mics_fit',5,'anchor_win_deg',40,'grid_step_deg',1));
% Zone 2 (inside_y / "maze pre-junction") only has 4 candidate mics, below the
% global min_mics_fit=5, so it always fell back to peak-mic. Allow a LOWER
% min_mics_fit for zone 2 ONLY so those calls can still attempt interpolation.
% Other zones keep est_opts.min_mics_fit. Set cfg.min_mics_fit_zone2 to tune.
min_mics_fit_zone2 = getdef(cfg,'min_mics_fit_zone2',4);

bpp = load(bp_proc_file);

%% --- bat trajectory + maze (for zone classification only) ---
[maze_track, frame_rate, maze, track_is_mm] = local_get_track_and_maze(bpp, bat_pos_file);
zones = build_maze_zones(maze);

%% --- mic number <-> column mapping (mic_loc row order) ---
mic_num_of_col = local_mic_numbers(bpp.mic_names);          % 1 x num_mics
valid_col      = ~isnan(mic_num_of_col) & ~isnan(bpp.mic_loc(:,1))';
all_mic_nums   = mic_num_of_col(valid_col);

% mic-selection mode: 'zone' (static per-zone INCLUDE/EXCLUDE lists) or
% 'lineofsight' (geometry: keep mics whose straight path to the bat doesn't cross
% a maze wall). Line-of-sight fixes cases where the zone list excludes visible
% mics that actually see the forward beam (e.g. a bat below the exits).
mic_select  = getdef(cfg,'mic_select','zone');
mics_xy_mm  = bpp.mic_loc(valid_col,1:2) * 1000;    % mm, same order as all_mic_nums
maze_walls  = {zones.wallR, zones.wallL};

%% --- pick dB field + frequency vectors ---
db_field = local_pick_db_field(bpp.proc, db_field);
fprintf('Using dB field: %s\n', db_field);
rms_freq_vec = [];
if isfield(bpp,'param') && isfield(bpp.param,'RMS_freq_vec')
    rms_freq_vec = bpp.param.RMS_freq_vec(:);
end

%% --- per-call bookkeeping ---
audio_fs       = bpp.mic_data.fs;
call_start_idx = [bpp.mic_data.call.call_start_idx];
calls_w_track  = bpp.mic_data.call_idx_w_track;
num_calls      = numel(calls_w_track);
num_mics       = size(bpp.mic_loc,1);
n_frames       = size(maze_track,1);

beam_aim_deg  = nan(num_calls,2);
beam_sigma    = nan(num_calls,1);
beam_method   = zeros(num_calls,1);
beam_peak_deg = nan(num_calls,2);
beam_zone_id  = zeros(num_calls,1);
beam_sel_mic  = nan(num_calls,1);
beam_n_used   = zeros(num_calls,1);

for iC = 1:num_calls
    %% 1) zone from the bat position at emission (self-consistent with stage 1)
    % Classify the zone directly from proc.bat_loc_at_call -- the emission
    % position stage 1 already solved on the track and that also feeds the beam
    % estimate below. Using the SAME position for mic selection and beam
    % geometry means the two can never disagree.
    %
    % This deliberately replaces the previous approach of re-deriving a Vicon
    % frame from the audio sample index (call_start_idx/audio_fs + sync_offset).
    % That assumed audio and Vicon shared t=0 at the START of the recording,
    % which contradicts stage 1 (its time bases meet at the END, via -fliplr)
    % and ignores the true Vicon<->Avisoft offset. Temporal alignment therefore
    % belongs in stage 1 (where emission-on-track is solved), not here.
    % NB: assumes cfg.axis_orient in stage 1 puts positions in the maze
    % (Vicon-global) frame -- true for the default axis_orient = [1 2 3].
    bat_maze_xy = bpp.proc.bat_loc_at_call(iC,1:2) * 1000;   % m -> mm (maze frame)
    if any(~isfinite(bat_maze_xy)), continue; end

    if strcmpi(mic_select,'lineofsight')
        sel_mic_nums = select_mics_lineofsight(bat_maze_xy, mics_xy_mm, all_mic_nums, maze_walls);
        [~, zid]     = select_mics_by_position(bat_maze_xy, zones, all_mic_nums);   % zone id: reporting only
    else
        [sel_mic_nums, zid] = select_mics_by_position(bat_maze_xy, zones, all_mic_nums);
    end
    beam_zone_id(iC) = zid;
    if isempty(sel_mic_nums), continue; end
    sel_cols = find(ismember(mic_num_of_col, sel_mic_nums));
    beam_n_used(iC) = numel(sel_cols);

    %% 2) dB at freq_desired for each selected mic (correct freq pairing)
    call_dB = nan(1,num_mics);
    for iM = sel_cols
        intensity = bpp.proc.(db_field){iC,iM};
        if isempty(intensity), continue; end
        freqs = local_freq_for_cell(bpp.proc.call_freq_vec{iC,iM}, ...
                                    numel(intensity), rms_freq_vec);
        [~,fidx] = min(abs(freqs - freq_desired*1e3));
        call_dB(iM) = intensity(fidx);
    end

    %% 3) beam-aim estimate = head-direction proxy (room frame, from bat_loc_at_call)
    bat_beam_xyz = bpp.proc.bat_loc_at_call(iC,:);          % metres, mic_loc frame
    est_opts_c = est_opts;                                   % per-call options
    if zid == 2                                              % zone 2 only: lower threshold
        est_opts_c.min_mics_fit = min_mics_fit_zone2;
    end
    bd = estimate_beam_direction(bpp.mic_loc(sel_cols,:), bat_beam_xyz, ...
                                 call_dB(sel_cols)', est_opts_c);

    beam_aim_deg(iC,:)  = [bd.az_deg, bd.el_deg];
    beam_sigma(iC)      = bd.sigma_deg;
    beam_peak_deg(iC,:) = [bd.peak_az_deg, bd.peak_el_deg];
    switch bd.method
        case {'anchored','midline','peak2d','interp'}
            beam_method(iC) = 1;   % continuous interpolation-based estimate
        case 'peak'
            beam_method(iC) = 2;   % too few mics -> loudest-mic fallback
        otherwise
            beam_method(iC) = 0;   % 'none' -> no estimate at all
    end

    % which selected mic was loudest (for auditing) -> its mic NUMBER
    [~,peak_col_rel] = max(call_dB(sel_cols));
    if ~isempty(peak_col_rel) && isfinite(call_dB(sel_cols(peak_col_rel)))
        beam_sel_mic(iC) = mic_num_of_col(sel_cols(peak_col_rel));
    end
end

out = struct('beam_aim_az_el_deg',beam_aim_deg, 'beam_aim_sigma_deg',beam_sigma, ...
             'beam_aim_method',beam_method, 'beam_peak_az_el_deg',beam_peak_deg, ...
             'beam_zone_id',beam_zone_id, 'beam_sel_mic_num',beam_sel_mic, ...
             'beam_n_mics_used',beam_n_used, 'zones',zones);

if save_back
    bpp.proc.beam_aim_az_el_deg  = beam_aim_deg;
    bpp.proc.beam_aim_sigma_deg  = beam_sigma;
    bpp.proc.beam_aim_method     = beam_method;
    bpp.proc.beam_peak_az_el_deg = beam_peak_deg;
    bpp.proc.beam_zone_id        = beam_zone_id;
    bpp.proc.beam_sel_mic_num    = beam_sel_mic;
    bpp.proc.beam_n_mics_used    = beam_n_used;
    save(bp_proc_file,'-struct','bpp');
    fprintf('Saved beam-aim (%d calls) back to %s\n', num_calls, bp_proc_file);
end

fprintf('\nMethod used:  interp=%d   peak-fallback=%d   none=%d\n', ...
        sum(beam_method==1), sum(beam_method==2), sum(beam_method==0));
fprintf('Zone usage across %d calls:\n', num_calls);
for z = 1:5
    fprintf('  zone %d %-18s : %d calls\n', z, zones.zone_names{z}, sum(beam_zone_id==z));
end
fprintf('  no-track/NaN            : %d calls\n', sum(beam_zone_id==0));
end

%% ===================== helpers =====================
function v = getdef(s, f, d)
% return s.f if present & non-empty, else default d
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

function nums = local_mic_numbers(mic_names)
% Parse the trailing integer from names like 'Mic_12' -> 12. NaN if unparseable.
    mic_names = cellstr(mic_names);
    nums = nan(1,numel(mic_names));
    for i = 1:numel(mic_names)
        tok = regexp(mic_names{i}, '(\d+)\s*$', 'tokens', 'once');
        if ~isempty(tok), nums(i) = str2double(tok{1}); end
    end
end

function name = local_pick_db_field(proc, requested)
% Prefer a compensated, bp-corrected dB field (matches beam_aim.m intent).
    if ~isempty(requested)
        assert(isfield(proc,requested), 'db_field "%s" not in proc.', requested);
        name = requested; return;
    end
    prefs = {'call_RMS_dB_comp_re20uPa_withbp', ...
             'call_psd_dB_comp_re20uPa_withbp', ...
             'call_psd_dB_comp_re20uPa_nobp', ...
             'call_psd_dB_comp_withbp', ...
             'call_rms_dB'};
    fn = fieldnames(proc);
    for i = 1:numel(prefs)
        if any(strcmp(fn, prefs{i})), name = prefs{i}; return; end
    end
    % last resort: any field with RMS/PSD + dB, like RIe_beamdirection.m
    hit = find(contains(fn,'dB','IgnoreCase',true) & ...
               (contains(fn,'RMS','IgnoreCase',true)|contains(fn,'psd','IgnoreCase',true)),1);
    assert(~isempty(hit), 'No dB intensity field found in proc.');
    name = fn{hit};
end

function freqs = local_freq_for_cell(fv_call, L, rms_freq_vec)
% Pair the intensity vector (length L) with a matching-length frequency axis.
% Fixes the RIe_beamdirection.m issue of truncating a 63-pt PSD freq axis onto
% a 12-pt RMS intensity vector. Returns freqs in Hz.
    fv_call = fv_call(:);
    if L == numel(fv_call)
        freqs = fv_call;
    elseif ~isempty(rms_freq_vec) && L == numel(rms_freq_vec)
        freqs = rms_freq_vec;
    else
        freqs = fv_call(1:min(L,numel(fv_call)));
        if numel(freqs) < L, freqs(end+1:L) = freqs(end); end
    end
    if max(freqs) < 1000, freqs = freqs*1e3; end   % kHz -> Hz guard
end

function [track, fr, maze, is_mm] = local_get_track_and_maze(bpp, bat_pos_file)
% Prefer an explicit bat_pos.mat (position pipeline; mm). Fall back to a track
% embedded in the bp_proc file (metres).
    if ~isempty(bat_pos_file)
        bp = load(bat_pos_file);
        track = bp.bat_pos;
        if iscell(track), track = track{1}; end
        fr    = double(bp.frame_rate);
        maze  = bp.maze;
        is_mm = true;
        return;
    end
    if isfield(bpp,'track') && isfield(bpp.track,'track_smooth')
        track = bpp.track.track_smooth;
        fr    = bpp.track.fs;
        is_mm = median(abs(track(isfinite(track))),'omitnan') > 100;  % m vs mm guess
    else
        error('No bat_pos_file given and no bpp.track.track_smooth found.');
    end
    if isfield(bpp,'maze'), maze = bpp.maze;
    else, error('No maze found. Pass a bat_pos_file (it embeds .maze).');
    end
end
