%% Beam-pattern pipeline -- WHOLE SESSION (batch over every trial)
% Batch sibling of beam_pipeline_one_trial.m. Runs the SAME end-to-end flow
%   stage 1 bp_proc_vicon -> stage 2+3 run_beamaim_maze -> QC plots -> stage 4
% for EVERY trial in one session (one batID + one date), instead of one trial.
%
% TRIAL DISCOVERY (hands-off "whole session"):
%   Scans the position pipeline's Bat_Position folder for this session's bat_pos
%   files (<batID>_<date>_<NN>_bat_pos.mat) and processes each. A trial's
%   position (bat_pos) must be done first -- which the beam analysis needs anyway
%   -- so those files are the natural per-session trial list. To restrict/reorder,
%   set trials_override = [3 4 5] (trial numbers) below.
%
%   For each trial it builds the four inputs bp_proc_vicon needs:
%     bat_pos_file  = <bat_pos_dir>\<batID>_<date>_<NN>_bat_pos.mat   (the anchor)
%     mic_pos_file  = <mic_pos_dir>\mic_pos_<date>.mat                (one per session)
%     combined_file = <combined_dir>\<combined_pat>                   (raw Avisoft)
%     detected_file = <detected_dir>\<detected_pat>                   (call_detect)
%   combined/detected live in the raw-data tree, so their folder + name PATTERN
%   are EDIT-ME below. Tokens: <batID>, <date> in the dir; %D%->date,
%   %T7%->7-digit trial (e.g. 0000003), %N%->trial number as-is in the pattern.
%   A trial whose combined/detected file is missing is SKIPPED with a warning
%   (never crashes the session).
%
% Each trial is wrapped in try/catch; a per-trial + pooled summary prints at end.
% Re-running a trial replaces its stage-4 rows (keyed on bat/session/trial), so
% re-running the session is safe.
%
% Written 2026-07-18 as the batch sibling of beam_pipeline_one_trial.m.

%% 0. Paths (once per MATLAB session)
setup_paths

%% ============================ CONFIG (EDIT ME) ============================
batID     = 'batA125';
date_data = '20260709';

% -- which stages to run per trial --
do_stage1  = true;   % stage 1  bp_proc_vicon (per-mic distance-compensated levels)
do_stage23 = true;   % stage 2+3 run_beamaim_maze (line-of-sight mic selection)
do_stage4  = true;   % stage 4  run_trial_analysis (trial metrics + study tables)
make_plots = true;   % per-trial QC plots (saved to disk, then figures closed)

% -- position-pipeline inputs (where position_processing writes) --
bat_pos_dir = 'Z:\Rie\Analysis\position_processing\Bat_Position';
mic_pos_dir = 'Z:\Rie\Analysis\position_processing\Mic_positions';

% -- raw Avisoft inputs: EDIT these roots + patterns to match your data tree.
%    (defaults follow beam_pipeline_one_trial.m's example paths -- confirm them.)
combined_dir = 'Z:\Rie\Data\Raw_Data\<batID>\<date>\Mic_data\Combined_trial_data';
combined_pat = 'T%T7%_combined.mat';           % e.g. T0000003_combined.mat
detected_dir = 'Z:\Rie\Data\Raw_Data\<batID>\done';
detected_pat = '%D%_T%T7%_detected.mat';       % e.g. 20260709_T0000003_detected.mat

% -- output roots (defaults match the single-trial scripts) --
out_root_proc  = 'Z:\Rie\Data\Beampattern_proc';        % stage-1 bp_proc .mat + plots (per bat)
out_root_stats = 'Z:\Rie\Stats\Beampattern_analysis';   % stage-4 study tables + plots

% -- optional explicit trial list (overrides auto-scan). [] = auto-scan bat_pos --
trials_override = [];
%% =========================================================================

% Resolve <batID>/<date> tokens in the raw-data folder roots.
combined_dir = strrep(strrep(combined_dir, '<batID>', batID), '<date>', date_data);
detected_dir = strrep(strrep(detected_dir, '<batID>', batID), '<date>', date_data);

mic_pos_file = fullfile(mic_pos_dir, sprintf('mic_pos_%s.mat', date_data));
if ~isfile(mic_pos_file)
    error('Session mic_pos file not found: %s (run position_processing first).', mic_pos_file);
end

% ---- build the trial list ----
if ~isempty(trials_override)
    trial_nums = trials_override(:).';
    bat_pos_files = arrayfun(@(n) fullfile(bat_pos_dir, ...
        sprintf('%s_%s_%02d_bat_pos.mat', batID, date_data, n)), trial_nums, 'UniformOutput', false);
else
    d = dir(fullfile(bat_pos_dir, sprintf('%s_%s_*_bat_pos.mat', batID, date_data)));
    trial_nums = []; bat_pos_files = {};
    for i = 1:numel(d)
        tok = regexp(d(i).name, sprintf('%s_%s_(\\d+)_bat_pos', batID, date_data), 'tokens', 'once');
        if ~isempty(tok)
            trial_nums(end+1)    = str2double(tok{1});                  %#ok<SAGROW>
            bat_pos_files{end+1} = fullfile(d(i).folder, d(i).name);    %#ok<SAGROW>
        end
    end
    [trial_nums, si] = sort(trial_nums);
    bat_pos_files    = bat_pos_files(si);
end
if isempty(trial_nums)
    error('No bat_pos files found for %s %s in %s', batID, date_data, bat_pos_dir);
end
fprintf('\n==== Beam session batch: %s %s -- %d trial(s) ====\n', batID, date_data, numel(trial_nums));

n_ok = 0; n_fail = 0; n_skip = 0;
failed = {}; skipped = {};
for i = 1:numel(trial_nums)
    n = trial_nums(i);
    bat_pos_file  = bat_pos_files{i};
    combined_file = fullfile(combined_dir, ...
        strrep(strrep(strrep(combined_pat,'%D%',date_data),'%T7%',sprintf('%07d',n)),'%N%',sprintf('%d',n)));
    detected_file = fullfile(detected_dir, ...
        strrep(strrep(strrep(detected_pat,'%D%',date_data),'%T7%',sprintf('%07d',n)),'%N%',sprintf('%d',n)));
    fprintf('\n---- [%d/%d] trial %02d ----\n', i, numel(trial_nums), n);

    if do_stage1 && (~isfile(combined_file) || ~isfile(detected_file))
        if ~isfile(combined_file), fprintf(2, '  missing combined_file: %s\n', combined_file); end
        if ~isfile(detected_file), fprintf(2, '  missing detected_file: %s\n', detected_file); end
        fprintf('  -> skipping trial %02d\n', n);
        skipped{end+1} = sprintf('%02d', n); n_skip = n_skip + 1; %#ok<SAGROW>
        continue;
    end

    try
        %% stage 1 -- bp_proc
        if do_stage1
            cfg = struct();
            cfg.combined_file = combined_file;
            cfg.detected_file = detected_file;
            cfg.bat_pos_file  = bat_pos_file;
            cfg.mic_pos_file  = mic_pos_file;
            cfg.tempC = []; cfg.humid = [];
            cfg.pos_units = 'mm'; cfg.axis_orient = [1 2 3]; cfg.head_normal = [0 0 1];
            cfg.mic_sens_file = ''; cfg.mic_bp_file = ''; cfg.mic_sens_dB = 0;
            cfg.out_dir = ''; cfg.out_name = '';
            cfg.out_root = out_root_proc;
            cfg.bat_id   = batID;
            data = bp_proc_vicon(cfg);
            bp_proc_file = data.saved_file;
        else
            % locate an existing bp_proc file for this trial (exact 7-digit match)
            bpdir = fullfile(out_root_proc, batID, 'beampattern_output');
            ex = dir(fullfile(bpdir, sprintf('%s_T%07d_mic_data_bp_proc.mat', date_data, n)));
            if isempty(ex)
                error('no existing bp_proc file for trial %02d in %s (set do_stage1=true)', n, bpdir);
            end
            bp_proc_file = fullfile(ex(1).folder, ex(1).name);
        end
        fprintf('  bp_proc_file = %s\n', bp_proc_file);

        %% stage 2+3 -- beam-aim per call
        out = [];
        if do_stage23
            out = run_beamaim_maze(struct( ...
                'bp_proc_file', bp_proc_file, ...
                'bat_pos_file', bat_pos_file, ...
                'mic_select',   'lineofsight'));
        end

        %% QC plots
        if make_plots
            try
                plot_mic_selection_qc(bat_pos_file, mic_pos_file);
                plot_beamaim_qc(bp_proc_file, out);
                close all;
            catch MEp
                fprintf(2, '  (QC plot warning trial %02d: %s)\n', n, MEp.message);
            end
        end

        %% stage 4 -- trial metrics + study tables
        if do_stage4
            run_trial_analysis(struct( ...
                'bp_proc_file', bp_proc_file, ...
                'bat_pos_file', bat_pos_file, ...
                'out_root',     out_root_stats, ...
                'plot',         make_plots));
            if make_plots, close all; end
        end

        n_ok = n_ok + 1;
    catch ME
        fprintf(2, '  TRIAL %02d FAILED: %s\n', n, ME.message);
        failed{end+1} = sprintf('%02d', n); n_fail = n_fail + 1; %#ok<SAGROW>
    end
end

fprintf('\n==== Beam session batch done: %d OK, %d failed, %d skipped ====\n', n_ok, n_fail, n_skip);
if ~isempty(failed),  fprintf('Failed:  %s\n', strjoin(failed,  ', ')); end
if ~isempty(skipped), fprintf('Skipped: %s\n', strjoin(skipped, ', ')); end

%% ---- pooled pre-flight beam figure across the session's trials ----
% (uses goal-relative azimuth, correct for pooling across moving perches)
if do_stage4 && make_plots
    pfmat = fullfile(out_root_stats, 'preflight_calls.mat');
    if isfile(pfmat)
        M = load(pfmat);   % variable T
        try
            plot_preflight_beam(M.T, [], [], struct('tag', sprintf('%s_%s', batID, date_data), ...
                'save_dir', fullfile(out_root_stats, 'plots')));
            close all;
        catch MEp
            fprintf(2, '(pooled plot warning: %s)\n', MEp.message);
        end
    end
end
