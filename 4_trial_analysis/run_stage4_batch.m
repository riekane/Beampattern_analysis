function run_stage4_batch()
%RUN_STAGE4_BATCH  Editable launcher for stage 4 over many trials.
%
%   run_stage4_batch
%
% This is the ONE place you invoke stage 4. Fill in the `trials` list (each row =
% one trial's fully-processed proc file + its position-pipeline bat_pos file),
% then run this. For each trial it calls run_trial_analysis, which internally
% runs every other stage-4 function and appends the two study tables in
% Z:\Rie\Stats\Beampattern_analysis. Re-running a trial replaces its rows (keyed
% on bat_id/session/trial), so it is safe to re-run.
%
% Requirements per trial: stage 1 (bp_proc_vicon) AND stage 3 (run_beamaim_maze)
% must already have been run, so the proc file carries proc.beam_aim_az_el_deg.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

setup_paths;                        % puts stages 1-4 (and 2's zone code) on the path

% ---- EDIT ME: one row per trial  { bp_proc_file , bat_pos_file } ----
trials = {
  'Z:\Rie\Data\Beampattern_proc\batA125\beampattern_output\20260709_T06_mic_data_bp_proc.mat', ...
  'Z:\Rie\Data\...\batA125_20260709_06_bat_pos.mat';
% add more rows here...
};

out_root = 'Z:\Rie\Stats\Beampattern_analysis';
make_plots = true;

for i = 1:size(trials,1)
    cfg = struct('bp_proc_file',trials{i,1}, 'bat_pos_file',trials{i,2}, ...
                 'out_root',out_root, 'plot',make_plots);
    try
        run_trial_analysis(cfg);
    catch ME
        fprintf(2, '  trial %d FAILED: %s\n', i, ME.message);
    end
end

% ---- pooled pre-flight beam figure across every trial written so far ----
% (uses the goal-relative azimuth, correct for pooling across moving perches)
pfmat = fullfile(out_root,'preflight_calls.mat');
if make_plots && isfile(pfmat)
    M = load(pfmat);                % variable T
    plot_preflight_beam(M.T, [], [], struct('tag','ALL_trials', ...
        'save_dir', fullfile(out_root,'plots')));
end

fprintf('Stage 4 batch done. Tables in %s\n', out_root);
end
