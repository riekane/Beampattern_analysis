%% run_bp_proc_vicon.m
% Entry script to PRODUCE a bp_proc_file for the Vicon + Avisoft rig.
%
% A "bp_proc_file" (…_mic_data_bp_proc.mat) is the output of the Magdiel
% pipeline's bp_proc.m step. It is the input that run_beamaim_maze.m /
% estimate_beam_direction.m consume. bp_proc_vicon.m reproduces that step for
% Rie's data: it is NON-INTERACTIVE (no uigetfile), reads Rie's own file
% formats, and — because there is no measured microphone calibration yet —
% treats the array as uniform Knowles FG capsules (see CALIBRATION below).
%
% HOW TO USE
%   1. Edit the CONFIG block below to point at one trial's files.
%   2. Run this script. It writes  <out_name>_mic_data_bp_proc.mat  into
%      out_dir, then you can run run_beamaim_maze.m on that file.
%
% CALIBRATION (important) --------------------------------------------------
%   With no measured per-mic sensitivity / beam-pattern, all mics are assumed
%   IDENTICAL Knowles FG capsules: flat sensitivity, omnidirectional, equal
%   gain. For BEAM DIRECTION this is sound — identical terms are the same for
%   every mic and cancel when you ask "which direction is loudest"; only the
%   distance-dependent transmission loss (spreading + air absorption, computed
%   from geometry + T/H) actually shifts the answer, and that needs no
%   calibration file. Absolute SPL values are therefore UNCALIBRATED (relative
%   only). When you measure real calibration, set cfg.mic_sens_file /
%   cfg.mic_bp_file and it will be used instead.
% -------------------------------------------------------------------------

%% ===================== CONFIG =====================
cfg = struct();

% -- this trial's inputs --
cfg.combined_file = 'Z:\...\Mic_data\Combined_trial_data\T0000016_combined.mat'; % sig + fs (raw multichannel Avisoft)
cfg.detected_file = 'Z:\...\batA125\done\20260625_T0000008_detected.mat';          % call struct from call_detect (YYYYMMDD_T{trial}_detected)
cfg.bat_pos_file  = 'Z:\Rie\Analysis\position_processing\Bat_Position\batA125_20260706_16_bat_pos.mat';
cfg.mic_pos_file  = 'Z:\Rie\Analysis\position_processing\Mic_positions\mic_pos_20260706.mat';

% -- template + shared code --
% Auto-located in 1_preprocessing\lib (self-contained). Set these only to override.
% cfg.params_file       = '';   % default: 1_preprocessing\lib\parameters_beam_pattern.mat
% cfg.preprocessing_dir = '';   % default: 1_preprocessing\lib

% -- environment --
% Leave both EMPTY ([]) to auto-pull temperature_C / humidity_pct from the
% detected file's meta (call_detect fills these from the master metadata CSV).
cfg.tempC = [];     % deg C  ([] = auto from detected meta)
cfg.humid = [];     % % RH   ([] = auto from detected meta)

% -- geometry conventions --
cfg.pos_units   = 'mm';       % units of mic_pos / bat_pos ('mm' or 'm'); converted to metres
cfg.axis_orient = [1 2 3];    % column permutation to get [x y z] Vicon-global; [1 2 3] = as-is
cfg.head_normal = [0 0 1];    % assumed head-normal (up) for the marker-free 1-marker track

% -- calibration (leave empty to assume uniform Knowles FG) --
cfg.mic_sens_file = '';       % e.g. 'Z:\Rie\Stats\Beampattern_analysis\20230920_mic_sens.mat' when measured
cfg.mic_bp_file   = '';       % e.g. 'Z:\Rie\Stats\Beampattern_analysis\20231005_mic_bp.mat'
cfg.mic_sens_dB   = 0;        % flat sensitivity used when no sens file (relative; 0 = no-op)

% -- output --
cfg.out_dir  = 'Z:\Rie\Analysis\Beampattern_analysis_inprogress';
cfg.out_name = '';            % '' -> derived from detected_file (e.g. batA125_20260706_16)
%% =================================================

data = bp_proc_vicon(cfg);
fprintf('\nDone. Next: set bp_proc_file in run_beamaim_maze.m to the saved file and run it.\n');
