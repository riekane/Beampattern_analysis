function plot_beamaim_qc(bp_proc_file, out, arrow_len_m)
%PLOT_BEAMAIM_QC  Top-view QC of the estimated beam-aim (head-direction proxy).
%
%   plot_beamaim_qc(bp_proc_file, out)
%   plot_beamaim_qc(bp_proc_file, out, arrow_len_m)
%
% Draws, in the room (Vicon global) top view:
%   * the mic positions (numbered),
%   * the bat position at each call,
%   * an arrow from each call showing the estimated beam-aim AZIMUTH, coloured
%     by how it was obtained (blue = interpolation+fit, red = peak-mic fallback).
%
% Run this after run_beamaim_maze.m to eyeball whether the proxy head-directions
% point sensibly (roughly along the flight / toward where the bat is heading).
%
% INPUT
%   bp_proc_file - the …_bp_proc[_checked].mat used in run_beamaim_maze.m.
%   out          - the struct returned by run_beamaim_maze.m (needs
%                  beam_aim_az_el_deg + beam_aim_method). If omitted, the fields
%                  are read back from proc in bp_proc_file.
%   arrow_len_m  - arrow length in metres (default 0.3).

if nargin < 3 || isempty(arrow_len_m), arrow_len_m = 0.3; end
bpp = load(bp_proc_file);

if nargin < 2 || isempty(out)
    out.beam_aim_az_el_deg = bpp.proc.beam_aim_az_el_deg;
    out.beam_aim_method    = bpp.proc.beam_aim_method;
end

bat = bpp.proc.bat_loc_at_call;                 % calls x 3 (metres)
mic = bpp.mic_loc;                              % mics x 3
az  = deg2rad(out.beam_aim_az_el_deg(:,1));
meth = out.beam_aim_method;

figure('Color','w','Position',[80 80 900 780]); hold on; axis equal; grid on;

% mics
good = ~isnan(mic(:,1));
plot(mic(good,1), mic(good,2), 'ok', 'MarkerFaceColor',[.75 .75 .75]);
text(mic(good,1), mic(good,2), num2str(find(good)), 'FontSize',8, ...
     'VerticalAlignment','bottom');

% bat trajectory through the calls (order = call order)
plot(bat(:,1), bat(:,2), '-', 'Color',[.6 .6 .6]);

% beam-aim arrows
blue = [0 109 219]/255; red = [228 26 28]/255;
for iC = 1:size(bat,1)
    if isnan(az(iC)) || isnan(bat(iC,1)), continue; end
    dx = arrow_len_m*cos(az(iC)); dy = arrow_len_m*sin(az(iC));
    if meth(iC) == 2, col = red; else, col = blue; end
    plot(bat(iC,1), bat(iC,2), '.', 'Color',col, 'MarkerSize',14);
    quiver(bat(iC,1), bat(iC,2), dx, dy, 0, 'Color',col, ...
           'LineWidth',2, 'MaxHeadSize',2);
end

xlabel('X (m)'); ylabel('Y (m)');
title('Beam-aim (head-direction proxy) — top view');
h1 = plot(nan,nan,'-','Color',blue,'LineWidth',2);
h2 = plot(nan,nan,'-','Color',red,'LineWidth',2);
legend([h1 h2], {'interp + Gaussian fit','peak-mic fallback'}, 'Location','best');
box on;
end
