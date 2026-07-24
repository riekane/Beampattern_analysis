function setup_paths()
%SETUP_PATHS  Add all pipeline code folders to the MATLAB path.
%
%   setup_paths
%
% Run this once per MATLAB session before using the pipeline (the Live Script
% beam_pattern_pipeline.mlx calls it in its first section). Adds the three stage
% folders and their lib/ subfolders. Does NOT add docs/ or archive/.

root = fileparts(mfilename('fullpath'));
addpath(root);
addpath(genpath(fullfile(root,'1_preprocessing')));
addpath(genpath(fullfile(root,'2_mic_zone_selection')));
addpath(genpath(fullfile(root,'3_beam_direction')));
addpath(fullfile(root,'4_trial_analysis'));
fprintf('Beam-pattern pipeline paths added (%s).\n', root);
end
