function data = bp_proc_vicon(cfg)
%BP_PROC_VICON  Produce a bp_proc_file for the Vicon + Avisoft rig (non-interactive).
%
%   data = BP_PROC_VICON(cfg)
%
% WITHOUT the GUI/uigetfile front-end and WITHOUT measured microphone
% calibration. It:
%   1. loads a parameters template,
%   2. builds the bat track & (marker-free) head aim from a single-marker Vicon
%      trajectory,
%   3. synthesises a UNIFORM Knowles-FG calibration (flat sensitivity, omni
%      beam pattern, equal gain) unless real calibration files are provided,
%   4. reuses the proven DSP/compensation functions in .\lib\
%      (get_time_series_around_call_fcn, get_call_fcn, compensate_call_dB_fcn,
%      air_absorption_vec, find_mic_az_el_to_bat_fcn),
%   5. saves  <out_name>_mic_data_bp_proc.mat  into cfg.out_dir.
%
% The saved file has the same shape run_beamaim_maze.m / estimate_beam_direction.m
% expect: proc.call_psd_dB_comp_re20uPa_withbp, proc.call_freq_vec,
% proc.bat_loc_at_call, mic_loc, mic_names, mic_data.call_idx_w_track, etc.
%
% See run_bp_proc_vicon.m for the CONFIG block and field documentation.
%

% Vicon+Avisoft beam-pattern pipeline, 2026.

% ---- dependencies (self-contained: local lib\ subfolder) ----
% The DSP/compensation helpers live in this folder's own lib\ subfolder
% (get_call_fcn, get_time_series_around_call_fcn, compensate_call_dB_fcn,
% air_absorption_vec, find_mic_az_el_to_bat_fcn, find_click_range) — no external
% example folder is needed.
here     = fileparts(mfilename('fullpath'));
prep_dir = fullfile(here,'lib');
if isfield(cfg,'preprocessing_dir') && ~isempty(cfg.preprocessing_dir)
    prep_dir = cfg.preprocessing_dir;               % optional override
end
assert(isfolder(prep_dir), 'lib folder not found: %s', prep_dir);
addpath(prep_dir);

% ---- temperature / humidity: fall back to the call_detect metadata ----
% call_detect auto-fills meta.temperature_C / meta.humidity_pct from the master
% metadata CSV, and saves them in the detected file. If cfg.tempC/humid are left
% empty/NaN here, pull them from there so you don't re-type them.
if isempty(cfg.tempC) || any(isnan(cfg.tempC)) || isempty(cfg.humid) || any(isnan(cfg.humid))
    try
        Mm = load(cfg.detected_file,'meta');
        if isfield(Mm,'meta')
            if (isempty(cfg.tempC)||any(isnan(cfg.tempC))) && isfield(Mm.meta,'temperature_C')
                cfg.tempC = double(Mm.meta.temperature_C);
            end
            if (isempty(cfg.humid)||any(isnan(cfg.humid))) && isfield(Mm.meta,'humidity_pct')
                cfg.humid = double(Mm.meta.humidity_pct);
            end
        end
    catch, end
end
assert(~isempty(cfg.tempC) && ~any(isnan(cfg.tempC)), ...
    'Temperature not set: cfg.tempC is empty and not found in the detected file meta.');
assert(~isempty(cfg.humid) && ~any(isnan(cfg.humid)), ...
    'Humidity not set: cfg.humid is empty and not found in the detected file meta.');
fprintf('Using T = %.1f C, H = %.0f %%\n', cfg.tempC, cfg.humid);

% ================= 1. parameters template =================
params_file = fullfile(prep_dir,'parameters_beam_pattern.mat');
if isfield(cfg,'params_file') && ~isempty(cfg.params_file)
    params_file = cfg.params_file;                  % optional override
end
S = load(params_file,'data');
data = S.data;                                   % data.param + data.track defaults

data.param.tempC = cfg.tempC;
data.param.humid = cfg.humid;
data.param.axis_orient = cfg.axis_orient;
data.param.dura_flag = 1;                        % use call_detect start/end marks
data.param.head_aim_prescribed = 0;              % marker-free: head aim from track velocity
data.track.head_n_prescribe = cfg.head_normal(:)';
[~,~,data.param.c,data.param.c_iso] = air_absorption_vec(1e3,data.param.tempC,data.param.humid);

unit_scale = 1.0; if strcmpi(cfg.pos_units,'mm'), unit_scale = 1e-3; end   % -> metres

% ================= 2. mic info (positions) =================
data = local_load_mic_info(data, cfg, unit_scale);

% ================= 3. bat position + marker-free head aim =================
data = local_load_bat_pos(data, cfg, unit_scale);

% ================= 4. mic data + call detection =================
data = local_load_mic_data(data, cfg);
if isempty(data.mic_data.call_idx_w_track)
    error('No detected calls fall within the tracked flight segment for this trial.');
end

% ================= 5. calibration (uniform Knowles FG, or measured) =================
data = local_load_calibration(data, cfg);   % needs nch + fs, so after mic_data

% ================= 6. angles (geometry) =================
data = local_time_delay_btwn_bat_mic(data);
data = local_mic2bat(data);
data = local_bat2mic(data);

% ================= 7. reserve GUI-check fields =================
nC = numel(data.mic_data.call_idx_w_track);
data.proc.chk_good_call = ones(nC,1);            % default: all good (no GUI here)
data.proc.ch_ex{nC} = [];

% ================= 8. call amplitude + compensation (reused DSP) =================
data = get_time_series_around_call_fcn(data);
data = get_call_fcn(data, 0);
data = compensate_call_dB_fcn(data);

% ================= 9. trim + save =================
if isfield(data.proc,'call_align'),    data.proc = rmfield(data.proc,'call_align');    end
if isfield(data.proc,'call_no_align'), data.proc = rmfield(data.proc,'call_no_align'); end
if isfield(data.mic_data,'sig'),       data.mic_data = rmfield(data.mic_data,'sig');   end

out_name = cfg.out_name;
if isempty(out_name)
    [~,b] = fileparts(cfg.detected_file);
    out_name = regexprep(b,'_?detected.*$','');
end

% ---- output folder: Data\Beampattern_proc\<batID>\ , organised per bat ----
% If cfg.out_dir is given, it is used as-is (back-compat). Otherwise the file is
% written under a per-bat folder inside a common processed-data root:
%   <out_root>\<batID>\<out_name>_mic_data_bp_proc.mat
% batID is taken from cfg.bat_id, else parsed from the bat_pos file name
% (e.g. 'batA125_20260709_06_bat_pos.mat' -> 'batA125').
% Layout per bat:  <out_root>\<batID>\beampattern_output\  (the .mat files)
%                  <out_root>\<batID>\plot\               (QC figures)
if isfield(cfg,'out_dir') && ~isempty(cfg.out_dir)
    bat_dir = cfg.out_dir;                          % explicit override: treat as the bat folder
else
    if isfield(cfg,'out_root') && ~isempty(cfg.out_root)
        out_root = cfg.out_root;
    else
        out_root = 'Z:\Rie\Data\Beampattern_proc';   % default processed-data root
    end
    if isfield(cfg,'bat_id') && ~isempty(cfg.bat_id)
        bat_id = cfg.bat_id;
    else
        [~,bpn] = fileparts(cfg.bat_pos_file);
        tok = regexp(bpn,'^([^_]+)','tokens','once');   % first token before '_'
        assert(~isempty(tok), ['Could not parse batID from bat_pos_file name (%s); ' ...
               'set cfg.bat_id or cfg.out_dir.'], bpn);
        bat_id = tok{1};
    end
    bat_dir = fullfile(out_root, bat_id);
end
out_dir  = fullfile(bat_dir, 'beampattern_output');   % .mat outputs
plot_dir = fullfile(bat_dir, 'plot');                 % QC figures (used by the plot fcns)

if ~isfolder(out_dir),  mkdir(out_dir);  end
if ~isfolder(plot_dir), mkdir(plot_dir); end
save_name  = [out_name '_mic_data_bp_proc.mat'];
saved_file = fullfile(out_dir, save_name);
% ---- take-off-centred coordinate frame: adds data.takeoff_centered.* (raw kept) ----
data = add_takeoff_centered_coords(data);

data.saved_file = saved_file;                 % record where it went (for downstream)
data.plot_dir   = plot_dir;                   % where QC plots should be saved
save(saved_file,'-struct','data','-v7.3');
fprintf('Saved %s (%d calls with track)\n', saved_file, nC);
end

%% ======================================================================
%%  LOADERS (adapted for Rie's formats)
%% ======================================================================
function data = local_load_mic_info(data, cfg, unit_scale)
% Rie's Mic_positions file: mic_loc, mic_vec, mic_names (+ mic_pointing_direction).
% bp_proc also wants mic_vh and mic_gain; synthesise sensible defaults.
    A = load(cfg.mic_pos_file);
    ao = data.param.axis_orient;
    assert(isfield(A,'mic_loc'), 'mic_pos_file missing mic_loc.');
    data.mic_loc = A.mic_loc(:,ao) * unit_scale;               % metres, [x y z]
    if isfield(A,'mic_vec'), data.mic_vec = A.mic_vec(:,ao);
    elseif isfield(A,'mic_pointing_direction'), data.mic_vec = A.mic_pointing_direction(:,ao);
    else, data.mic_vec = repmat([0 0 1],size(data.mic_loc,1),1); end
    if isfield(A,'mic_names'), data.mic_names = cellstr(A.mic_names);
    else, data.mic_names = arrayfun(@(k)sprintf('Mic_%d',k),1:size(data.mic_loc,1),'uni',0)'; end
    data.mic_vh   = data.mic_vec;                               % vertical/horizontal aim (unused downstream)
    data.mic_gain = zeros(size(data.mic_loc,1),1);             % equal gain (uncalibrated)
end

function data = local_load_calibration(data, cfg)
% MIC CALIBRATION -- factory-flat default now, measured files later.
%
% Until per-mic calibration is measured, all mics are treated as identical
% Knowles-FG capsules: flat sensitivity (cfg.mic_sens_dB, default 0) and
% omnidirectional (0 dB) beam pattern. This is fine for BEAM DIRECTION (the
% identical terms cancel across mics); only absolute SPL is uncalibrated.
%
% TO FEED MEASURED CALIBRATION LATER, just set:
%   cfg.mic_sens_file -> .mat with
%        freq : (Nf x 1) frequency axis [Hz]
%        sens : (Nf x M) per-mic sensitivity [dB], columns = mic NUMBER order
%   cfg.mic_bp_file   -> .mat with
%        freq : (Nf x 1) [Hz],  theta : (Ntheta x 1) [deg]
%        bp   : (Nf x Ntheta x M) per-mic beam pattern [dB]
%
% M may be the FULL array (e.g. 31/32 mics) or exactly the recorded channel
% count. If it is the full array, the columns/pages are auto-subset to the
% channels actually recorded this session (data.mic_channels), so ONE
% calibration file works for both 24- and 31-channel sessions -- nothing else
% to change. No file -> factory-flat default below.
    nch    = size(data.mic_loc,1);                 % recorded channels (already subset)
    nyq    = data.mic_data.fs/2;
    ch2mic = data.mic_channels;                    % recorded channel -> mic index

    % ---- sensitivity ----
    if isfield(cfg,'mic_sens_file') && ~isempty(cfg.mic_sens_file)
        S = load(cfg.mic_sens_file);               % .freq, .sens
        assert(isfield(S,'sens') && isfield(S,'freq'), 'mic_sens_file needs .freq and .sens.');
        S.sens = local_pick_channels(S.sens, 2, nch, ch2mic, 'mic_sens.sens');
        data.mic_sens = S;
    else
        f = [0; nyq];                              % 2-pt flat curve (0..Nyquist)
        data.mic_sens = struct('freq',f, 'sens', cfg.mic_sens_dB*ones(numel(f),nch));
    end

    % ---- beam pattern ----
    if isfield(cfg,'mic_bp_file') && ~isempty(cfg.mic_bp_file)
        B = load(cfg.mic_bp_file);                 % .freq, .theta, .bp
        assert(all(isfield(B,{'bp','freq','theta'})), 'mic_bp_file needs .freq, .theta and .bp.');
        B.bp = local_pick_channels(B.bp, 3, nch, ch2mic, 'mic_bp.bp');
        data.mic_bp = B;
    else
        theta = (-180:180)';                       % deg
        f = [0; nyq];
        data.mic_bp = struct('theta',theta, 'freq',f, ...
                             'bp', zeros(numel(f),numel(theta),nch));  % omni -> 0 dB compensation
    end
end

function X = local_pick_channels(X, dim, nch, ch2mic, name)
% Align a per-mic calibration array to the recorded channels along dimension
% `dim`. Accept an array already sized to nch (use as-is), or a full-array
% calibration indexed by mic number (subset by ch2mic).
    n = size(X, dim);
    if n == nch
        return;                                    % already per recorded channel
    elseif n >= max(ch2mic)
        idx = repmat({':'}, 1, ndims(X));
        idx{dim} = ch2mic;                         % subset full array -> recorded channels
        X = X(idx{:});
    else
        error(['%s has %d entries along dim %d, but the session recorded %d channels ' ...
               '(max mic index %d). Provide calibration for the full array or the ' ...
               'recorded channels.'], name, n, dim, nch, max(ch2mic));
    end
end

function data = local_load_bat_pos(data, cfg, unit_scale)
% Rie's bat_pos.mat: bat_pos = (Nframes x 3) array + frame_rate (Hz) + maze.
% Single "marker" (mean of the two body markers) -> head aim from track velocity
% (the marker-free proxy replaced later by the beam-based estimate).
    B = load(cfg.bat_pos_file);
    pos = B.bat_pos;
    if iscell(pos), pos = cell2mat(pos); end
    ao = data.param.axis_orient;
    pos = pos(:,ao) * unit_scale;                              % metres
    data.track.fs = double(B.frame_rate);

    % Trim the Vicon tail to match the Avisoft recording length, so the END
    % alignment (Vicon last frame <-> Avisoft last sample, both built via
    % -fliplr) is correct. Keep the first round(cfg.vicon_dur_s * frame_rate)
    % frames (default 16 s -> 4000 @ 250 Hz). Set cfg.vicon_dur_s = Inf to disable.
    vdur = 16;
    if isfield(cfg,'vicon_dur_s') && ~isempty(cfg.vicon_dur_s), vdur = cfg.vicon_dur_s; end
    pos_full   = pos;                 % untrimmed track (m) -> used for the landing tail
    track_tail = [];
    if isfinite(vdur)
        nkeep = round(vdur * data.track.fs);
        if size(pos,1) > nkeep
            fprintf('Trimming Vicon track %d -> %d frames (%.2f s) to match Avisoft.\n', ...
                    size(pos,1), nkeep, vdur);
            track_tail = pos_full(nkeep:end, :);   % last kept frame + post-TTL landing tail (m)
            pos = pos(1:nkeep, :);
        end
    end
    if isfield(B,'maze'), data.maze = B.maze; end             % carried for run_beamaim_maze zones
    % Vicon-tracked perch positions (mm) -> carried through for QC plots, used
    % as a fallback when the JSON layout has no labelled perch.
    if isfield(B,'tp_position'), data.tp_position = B.tp_position; end  % take-off perch
    if isfield(B,'lp_position'), data.lp_position = B.lp_position; end  % landing perch
    if isfield(B,'perch_pos'),   data.perch_pos   = B.perch_pos;   end  % ALL perches (multi landing)

    sm_len   = data.track.smooth_len;
    diff_len = round(data.track.head_aim_est_time_diff*data.track.fs/1e3);
    track = pos;
    track_t = -fliplr(0:size(track,1)-1)/data.track.fs;       % [s], ending at 0

    seg_idx  = local_find_seg(track, sm_len);
    track_sm = local_sm_track(track, sm_len, seg_idx);

    % head aim from smoothed-track velocity (marker-free), head normal prescribed
    head_aim = nan(size(track_sm));
    n = size(track_sm,1);
    head_aim(1:n-diff_len+1,:) = [track_sm(diff_len:end,1:2)-track_sm(1:n-diff_len+1,1:2), ...
                                  zeros(n-diff_len+1,1)];
    head_aim = local_norm_mtx_vec(head_aim);
    head_n = nan(size(track_sm));
    ok = ~isnan(head_aim(:,1));
    head_n(ok,:) = repmat(data.track.head_n_prescribe,sum(ok),1);

    % interpolate to 1 ms for aligning calls
    dt = 1e-3;
    track_int_t = track_t(1):dt:track_t(end);
    track_int    = local_int_track(track_t, track_sm, track_int_t);
    head_aim_int = local_int_track(track_t, head_aim, track_int_t);
    head_n_int   = local_int_track(track_t, head_n,   track_int_t);

    data.track.marked_pos        = pos;
    data.track.track_raw         = track;
    data.track.track_raw_time    = track_t;
    data.track.track_smooth      = track_sm;
    data.track.track_interp      = track_int;
    data.track.track_interp_time = track_int_t;
    data.track.track_tail        = track_tail;               % post-TTL landing tail (m), for QC
    data.track.marker_indicator  = zeros(size(track_int,1),1);   % 0 = head aim from track
    data.head_aim.head_aim_smooth   = head_aim;
    data.head_aim.head_aim_int      = head_aim_int;
    data.head_normal.head_normal_smooth = head_n;
    data.head_normal.head_normal_int    = head_n_int;
end

function data = local_load_mic_data(data, cfg)
% Combined recording (sig, fs) + call_detect output (call struct).
    A  = load(cfg.combined_file);                 % sig, fs
    MD = load(cfg.detected_file);                 % call, num_ch_in_file, fs, ...
    assert(isfield(A,'sig'),'combined_file missing sig.');
    mic_data = MD;
    mic_data.sig = A.sig;
    if isfield(A,'fs'), mic_data.fs = A.fs; elseif ~isfield(mic_data,'fs'), mic_data.fs = 250000; end
    if ~isfield(mic_data,'num_ch_in_file'), mic_data.num_ch_in_file = size(A.sig,2); end
    mic_data.sig_t = -fliplr(0:size(mic_data.sig,1)-1)/mic_data.fs;
    data.mic_data = mic_data;

    % ---- channel <-> mic mapping (allow fewer channels than mics) ----
    % Rie's rig wires mic1->ch1, mic2->ch2, ... so recording channel k is
    % simply row k of mic_loc. Some sessions record all 31 mics, others only
    % the first 24; in the short case we just drop the unrecorded mic rows so
    % every per-mic array matches the number of channels actually present.
    % An explicit order can be forced with cfg.mic_channels (a vector of
    % mic_loc row indices, one entry per recorded channel) if the wiring ever
    % differs from the default 1:1.
    nch  = data.mic_data.num_ch_in_file;
    nmic = size(data.mic_loc,1);

    % Rig mic numbering: 31 physical mics numbered 1..29, 31, 32 (there is NO
    % Mic_30). Recording channel k is wired to the k-th mic in THIS order, so
    % channel 1..29 -> Mic_1..29, channel 30 -> Mic_31, channel 31 -> Mic_32.
    % (Edit CANON here if the rig's mic set ever changes.)
    canon = [1:29, 31, 32];

    if isfield(cfg,'mic_channels') && ~isempty(cfg.mic_channels)
        % explicit override: channel k -> mic_loc ROW cfg.mic_channels(k)
        ch2mic = cfg.mic_channels(:)';
        assert(numel(ch2mic)==nch, ...
            'cfg.mic_channels has %d entries but recording has %d channels.', ...
            numel(ch2mic), nch);
        assert(all(ch2mic>=1 & ch2mic<=nmic), ...
            'cfg.mic_channels indexes outside 1..%d (available mics).', nmic);
        map_by_number = false;
    else
        % DEFAULT: map channel k -> the mic_loc row whose MIC NUMBER is canon(k),
        % parsed from mic_names -- NOT the row's position in the file. A mic that
        % is MISSING from mic_pos that day (its landmark was not labelled/solved)
        % then leaves a NaN gap for its OWN channel instead of shifting every
        % later channel onto the next mic's location (the old 1:nch bug that
        % scrambled 20260703 / 20260720).
        assert(nch<=numel(canon), ...
            'Recording has %d channels but the rig only defines %d mics.', nch, numel(canon));
        mic_num = nan(1,nmic);
        for i = 1:nmic
            tok = regexp(char(data.mic_names{i}), '(\d+)', 'tokens', 'once');
            if ~isempty(tok), mic_num(i) = str2double(tok{1}); else, mic_num(i) = i; end
        end
        ch2mic = nan(1,nch);
        for k = 1:nch
            r = find(mic_num==canon(k), 1);
            if ~isempty(r), ch2mic(k) = r; end
        end
        map_by_number = true;
        miss = find(isnan(ch2mic));
        if ~isempty(miss)
            fprintf(['Channel/mic map: channel(s) [%s] (Mic_[%s]) have no position in ' ...
                     'mic_pos -- set to NaN so the other mics keep their true ' ...
                     'positions. Label/solve that mic in the landmark file if it ' ...
                     'should exist.\n'], num2str(miss), num2str(canon(miss)));
        end
    end
    data.mic_channels = ch2mic;   % recorded channel -> mic row (NaN = no mic for that channel)
    % NOTE: with a missing mic, mic_channels now contains NaN. That is fine for
    % the beam pipeline (estimate_beam_direction / run_beamaim_maze already drop
    % NaN-position mics). If per-mic CALIBRATION files are ever wired in
    % (local_load_calibration), make its subsetting skip NaN channels.

    % Rebuild every per-mic array with exactly ONE ROW PER RECORDED CHANNEL, in
    % channel order, NaN-filling any channel that has no mic. This guarantees
    % row k == channel k, so a missing mic can never renumber the others.
    have = ~isnan(ch2mic);
    src  = ch2mic(have);
    new_loc  = nan(nch,3);
    new_vec  = nan(nch,3);
    new_vh   = nan(nch,3);
    new_gain = zeros(nch,1);
    if map_by_number
        new_names = arrayfun(@(k) sprintf('Mic_%d',canon(k)), (1:nch)', 'UniformOutput', false);
    else
        new_names = arrayfun(@(k) sprintf('Mic_%d',k),        (1:nch)', 'UniformOutput', false);
    end
    new_loc(have,:) = data.mic_loc(src,:);
    new_vec(have,:) = data.mic_vec(src,:);
    new_vh(have,:)  = data.mic_vh(src,:);
    new_gain(have)  = data.mic_gain(src);
    nm = data.mic_names(src); new_names(have) = nm(:);
    data.mic_loc   = new_loc;
    data.mic_vec   = new_vec;
    data.mic_vh    = new_vh;
    data.mic_gain  = new_gain;
    data.mic_names = new_names;
    fprintf('Channel/mic map: %d channel(s); %d located, %d NaN (missing mic).\n', ...
            nch, sum(have), sum(~have));

    % Optional override of the extraction-window length (ms). The window is
    % centred on the predicted acoustic arrival at each mic; when the bat
    % position / Vicon-Avisoft timing is a few ms off, the marked call can fall
    % outside a short window (-> "Call duration marking is problematic"). A
    % longer window tolerates that offset so the call is still captured.
    if isfield(cfg,'extract_call_len_ms') && ~isempty(cfg.extract_call_len_ms)
        data.param.extract_call_len = cfg.extract_call_len_ms;
    end
    data.param.extract_call_len_pt  = round(data.param.extract_call_len*1e-3*data.mic_data.fs);
    data.param.extract_call_len_idx = -round((data.param.extract_call_len_pt+1)/2) + ...
                                       (1:data.param.extract_call_len_pt);
    data = local_get_call_on_seg_stuff(data);
end

function data = local_get_call_on_seg_stuff(data)
% Select detected calls that (a) have start/end marks, (b) fall on the track,
% (c) have enough flanking signal, (d) whose marked channel has a mic location.
    call_locs_ini = [data.mic_data.call.locs];
    call_locs_ini(call_locs_ini<1) = 1;
    call_time = data.mic_data.sig_t(call_locs_ini);

    nan_se = isnan([data.mic_data.call.call_start_idx]) | isnan([data.mic_data.call.call_end_idx]);
    [~,tt_idx] = min(abs(repmat(call_time,length(data.track.track_interp_time),1) - ...
                         repmat(data.track.track_interp_time',1,length(call_time))),[],1);
    notrack = isnan(data.head_aim.head_aim_int(tt_idx,1));
    good = find(~(nan_se(:)|notrack(:)));
    call_loc_idx = tt_idx(good);

    locs = [data.mic_data.call(good).locs];
    enough = (locs+data.param.extract_call_len_idx(1))>1 & ...
             (locs+data.param.extract_call_len_idx(end))<size(data.mic_data.sig,1);
    good = good(enough);

    ch_sel = [data.mic_data.call(good).channel_marked];
    nan_mic = find(isnan(data.mic_loc(:,1)));
    good = good(~ismember(ch_sel,nan_mic));

    data.mic_data.call_idx_w_track = good;
    data.track.call_loc_idx_on_track_interp = call_loc_idx;
end

%% ======================================================================
%%  ANGLE CALCS (copied from bp_proc.m; find_mic_az_el_to_bat_fcn on path)
%% ======================================================================
function data = local_time_delay_btwn_bat_mic(data)
    bat_traj = data.track.track_interp; mic_loc = data.mic_loc;
    bat_traj_time = data.track.track_interp_time(:);
    t = zeros(size(bat_traj,1),size(mic_loc,1));
    for iT=1:size(bat_traj,1)
        for iCH=1:data.mic_data.num_ch_in_file
            t(iT,iCH) = norm(bat_traj(iT,:)-mic_loc(iCH,:))/data.param.c;
        end
    end
    data.time_from_bat_to_mic = t;
    data.time_of_call_at_mic  = t + repmat(bat_traj_time,1,size(t,2));
end

function data = local_mic2bat(data)
    nC = numel(data.mic_data.call_idx_w_track);
    for iC=1:nC
        k = data.track.call_loc_idx_on_track_interp(iC);
        bat = data.track.track_interp(k,:);
        vec = data.mic_loc - repmat(bat,size(data.mic_loc,1),1);
        dist = sqrt(sum(vec.^2,2));
        vecn = vec./repmat(dist,1,3);
        aim = data.head_aim.head_aim_int(k,:);
        nor = data.head_normal.head_normal_int(k,:);
        [m2b,m2bx] = find_mic_az_el_to_bat_fcn(vecn,aim,nor);
        data.proc.bat_loc_at_call(iC,:)    = bat;
        data.proc.mic_to_bat_dist(iC,:)    = dist(:)';
        data.proc.mic_to_bat_vec(iC,:,:)   = vecn;
        data.proc.mic_to_bat_angle(iC,:,:) = m2b;
        data.proc.mic_to_bat_angle_x(iC,:,:) = m2bx;
        data.proc.source_head_aim(iC)      = data.track.marker_indicator(k);
    end
end

function data = local_bat2mic(data)
    nC = numel(data.mic_data.call_idx_w_track);
    if isfield(data.param,'zero_bat2mic_angle') && data.param.zero_bat2mic_angle
        data.proc.bat_to_mic_angle = zeros(nC,size(data.mic_loc,1)); return;
    end
    for iC=1:nC
        bat = repmat(data.proc.bat_loc_at_call(iC,:),size(data.mic_loc,1),1);
        b2m = bat - data.mic_loc;
        b2m = b2m./repmat(sqrt(sum(b2m.^2,2)),1,3);
        mvn = data.mic_vec./repmat(sqrt(sum(data.mic_vec.^2,2)),1,3);
        data.proc.bat_to_mic_angle(iC,:) = acos(sum(b2m.*mvn,2))';
    end
end

%% ======================================================================
%%  small helpers copied from bp_proc.m (find_seg / sm_track / int_track / norm)
%% ======================================================================
function seg_idx = local_find_seg(pos,sm_len)
    notnan = ~isnan(pos(:,1));
    idx_nan = find(diff(notnan)~=0)+1;
    g = normpdf(-sm_len:sm_len,0,sm_len);
    w = conv(double(notnan),g,'same');
    idx = find(diff(w~=0)~=0)+1;
    idx_up = find(diff(w~=0)>0)+1; idx_dn = find(diff(w~=0)<0)+1;
    if ~isempty(idx)
        [~,iconv] = min(abs(repmat(idx',length(idx_nan),1)-repmat(idx_nan,1,length(idx))),[],1);
        if isempty(idx_up) && ~isempty(idx_dn),      seg_idx = [1;idx_nan(iconv)];
        elseif ~isempty(idx_up) && isempty(idx_dn),  seg_idx = [idx_nan(iconv);size(pos,1)];
        else
            if idx_up(1)~=idx(1), seg_idx = [1;idx_nan(iconv)]; else, seg_idx = idx_nan(iconv); end
        end
    else
        seg_idx = [1,size(pos,1)];
    end
    if mod(length(seg_idx),2)~=0, seg_idx = [seg_idx;length(notnan)]; end
    seg_idx = reshape(seg_idx,2,[])';
end

function v_sm = local_sm_track(v,sm_len,seg_idx)
    v_sm = nan(size(v));
    for iS=1:size(seg_idx,1)
        a=seg_idx(iS,1); b=seg_idx(iS,2);
        for c=1:3, v_sm(a:b,c) = smooth(v(a:b,c),sm_len); end
    end
end

function v_int = local_int_track(x,v,x_int)
    v_int = zeros(numel(x_int),3);
    for c=1:3, v_int(:,c) = interp1(x,v(:,c),x_int); end
end

function m = local_norm_mtx_vec(mtx_v)
    dd = sqrt(sum(mtx_v.^2,2));
    m = mtx_v./repmat(dd,1,3);
end
