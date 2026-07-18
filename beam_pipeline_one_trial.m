%% Beam-pattern pipeline - one trial, end to end
% Run this section by section, or Save As -> .mlx for a Live Script.
% Order:  setup  ->  stage 1 (bp_proc)  ->  stage 2+3 (beam-aim, line-of-sight)
%         ->  QC plots  ->  stage 4 (trial metrics).
% All the stage functions take ONE struct argument (that was the "Too many input
% arguments" error - the old call passed positional args).

%% 0. Paths (once per MATLAB session)
setup_paths

%% 1. CONFIG - point at ONE trial's files   (EDIT the 4 paths)
batID = 'batA125';  date_data = '20260709';  trial = '03';

cfg = struct();
cfg.combined_file = 'Z:\...\T0000003_combined.mat';                 % raw Avisoft (sig + fs)   <-- EDIT
cfg.detected_file = 'Z:\...\20260709_T0000003_detected.mat';       % call_detect output       <-- EDIT
cfg.bat_pos_file  = 'Z:\Rie\Analysis\position_processing\Bat_Position\batA125_20260709_03_bat_pos.mat';
cfg.mic_pos_file  = 'Z:\Rie\Analysis\position_processing\Mic_positions\mic_pos_20260709.mat';

cfg.tempC = [];   cfg.humid = [];              % [] = auto-pull from detected-file meta
cfg.pos_units = 'mm';  cfg.axis_orient = [1 2 3];  cfg.head_normal = [0 0 1];
cfg.mic_sens_file = '';  cfg.mic_bp_file = '';  cfg.mic_sens_dB = 0;   % uniform Knowles FG
cfg.out_dir  = '';       % '' -> saves under Z:\Rie\Data\Beampattern_proc\<batID>\beampattern_output\
cfg.out_name = '';       % '' -> derived from detected_file
% cfg.vicon_dur_s = 16;  % (default) trim Vicon tail to 16 s so it end-aligns to Avisoft; Inf disables

%% 2. Stage 1 - bp_proc (per-mic distance-compensated levels; writes the bp_proc file)
data = bp_proc_vicon(cfg);          % watch for "Trimming Vicon track ... to match Avisoft."
bp_proc_file = data.saved_file;
bat_pos_file = cfg.bat_pos_file;
fprintf('bp_proc_file = %s\n', bp_proc_file);

%% 3. Stage 2+3 - beam-aim per call, with LINE-OF-SIGHT mic selection
out = run_beamaim_maze(struct( ...
        'bp_proc_file', bp_proc_file, ...
        'bat_pos_file', bat_pos_file, ...
        'mic_select',   'lineofsight'));     % use 'zone' for the old static per-zone lists

%% 4. QC plots
plot_mic_selection_qc(bat_pos_file, cfg.mic_pos_file);   % zoning geometry
plot_beamaim_qc(bp_proc_file, out);                      % beam-aim arrows

%% 5. Stage 4 - trial metrics (landing / side / pre-flight; writes the study tables)
res = run_trial_analysis(struct( ...
        'bp_proc_file', bp_proc_file, ...
        'bat_pos_file', bat_pos_file, ...
        'plot', true));
disp(res.trial_row)
fprintf('pre-flight calls: %d\n', height(res.preflight_calls));
