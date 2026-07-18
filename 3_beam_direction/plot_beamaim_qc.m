function plot_beamaim_qc(bp_proc_file, out, arrow_len_m, save_png)
%PLOT_BEAMAIM_QC  Top-view QC of the estimated beam-aim
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
if nargin < 4, save_png = ''; end   % '' -> auto path (bat's \plot folder); 'none' -> don't save
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

% ---- full flight path: SOLID where Vicon tracked, DASHED across gaps ----
% track_interp is NaN across tracking gaps, so its valid runs are the truly
% tracked segments; the straight bridges between runs are interpolated (the
% bat's position there was not measured). Falls back to connecting the call
% positions if no interpolated track is stored (older files).
traj_h = gobjects(1,0); traj_l = {};
trajcol = [.55 .55 .55];
if isfield(bpp,'track') && isfield(bpp.track,'track_interp') && ~isempty(bpp.track.track_interp)
    T = bpp.track.track_interp;                          % 1 ms track (metres)
    v = ~isnan(T(:,1));
    d = diff([0; double(v); 0]);
    runS = find(d==1); runE = find(d==-1)-1;             % contiguous tracked runs
    hs = gobjects(0); hd = gobjects(0);
    for k = 1:numel(runS)                                % solid = tracked
        hh = plot(T(runS(k):runE(k),1), T(runS(k):runE(k),2), '-', ...
                  'Color',trajcol, 'LineWidth',1);
        if isempty(hs), hs = hh; end
    end
    for k = 1:numel(runS)-1                              % dashed = interpolated bridge
        hh = plot([T(runE(k),1) T(runS(k+1),1)], [T(runE(k),2) T(runS(k+1),2)], '--', ...
                  'Color',trajcol, 'LineWidth',1);
        if isempty(hd), hd = hh; end
    end
    if ~isempty(hs), traj_h(end+1) = hs; traj_l{end+1} = 'tracked path'; end
    if ~isempty(hd), traj_h(end+1) = hd; traj_l{end+1} = 'interpolated (gap)'; end
else
    plot(bat(:,1), bat(:,2), '-', 'Color',[.6 .6 .6]);  % fallback: connect calls
end

% ---- maze overlay (walls / start line / perches) ----
% The maze struct (carried in the bp_proc file) is in mm, Vicon-global; this
% plot is in metres, so convert. Y-maze walls are the two 3-point polylines.
% Perches are shown with distinct marks: take-off = gold star, landing = cyan
% diamond. Their handles/labels are collected for the legend.
perch_h = gobjects(1,0); perch_l = {};
s = 1e-3;                                          % mm -> m
if isfield(bpp,'maze') && ~isempty(bpp.maze)
    mz = bpp.maze;
    if isfield(mz,'left_wall')
        plot(mz.left_wall(:,1)*s,  mz.left_wall(:,2)*s,  '-o','Color',[.2 .2 .2], ...
             'LineWidth',2,'MarkerSize',4,'HandleVisibility','off');
    end
    if isfield(mz,'right_wall')
        plot(mz.right_wall(:,1)*s, mz.right_wall(:,2)*s, '-o','Color',[.2 .2 .2], ...
             'LineWidth',2,'MarkerSize',4,'HandleVisibility','off');
    end
    if isfield(mz,'start_line')
        plot(mz.start_line(:,1)*s, mz.start_line(:,2)*s, 'k--', ...
             'LineWidth',1.2,'HandleVisibility','off');
    end
end
% perches: prefer the JSON-labelled maze perch, else the Vicon-tracked position.
tp = local_perch(bpp,'takeoff_perch','tp_position');
lp = local_perch(bpp,'landing_perch','lp_position');
if ~isempty(tp)
    perch_h(end+1) = scatter(tp(1)*s, tp(2)*s, 200,'p', ...
            'MarkerFaceColor',[1 .84 0],'MarkerEdgeColor','k');
    perch_l{end+1} = 'take-off perch';
end
if ~isempty(lp)
    perch_h(end+1) = scatter(lp(1)*s, lp(2)*s, 240,'d', ...
            'MarkerFaceColor',[0 .70 .90],'MarkerEdgeColor','k');
    perch_l{end+1} = 'landing perch';
end

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
legend([h1 h2 traj_h perch_h], ...
       [{'interp + Gaussian fit','peak-mic fallback'} traj_l perch_l], 'Location','best');
box on;

% ---- save the QC figure into the bat's \plot folder ----
% Default target: the plot_dir recorded by bp_proc_vicon (…\<batID>\plot). If
% that isn't in the file (older run), fall back to a 'plot' folder next to the
% bp_proc file. Pass save_png='none' to skip, or an explicit path/folder.
if ~strcmpi(save_png,'none')
    if isempty(save_png)
        if isfield(bpp,'plot_dir') && ~isempty(bpp.plot_dir)
            plot_dir = bpp.plot_dir;
        else
            plot_dir = fullfile(fileparts(fileparts(bp_proc_file)), 'plot');
        end
        [~,base] = fileparts(bp_proc_file);
        base = regexprep(base,'_mic_data_bp_proc$','');
        save_png = fullfile(plot_dir, [base '_beamaim_qc.png']);
    elseif isfolder(save_png)                       % a folder was given -> auto filename
        [~,base] = fileparts(bp_proc_file);
        base = regexprep(base,'_mic_data_bp_proc$','');
        save_png = fullfile(save_png, [base '_beamaim_qc.png']);
    end
    pdir = fileparts(save_png);
    if ~isempty(pdir) && ~isfolder(pdir), mkdir(pdir); end
    saveas(gcf, save_png);
    fprintf('Saved QC plot %s\n', save_png);
end
end

function p = local_perch(bpp, maze_field, vicon_field)
% Resolve a perch [x y z] (mm): prefer the JSON-labelled maze perch, else the
% Vicon-tracked perch position carried in the bp_proc file. Empty if neither.
    p = [];
    if isfield(bpp,'maze') && isstruct(bpp.maze) && isfield(bpp.maze,maze_field) ...
            && ~isempty(bpp.maze.(maze_field))
        p = bpp.maze.(maze_field);
    elseif isfield(bpp,vicon_field) && ~isempty(bpp.(vicon_field))
        p = bpp.(vicon_field);
    end
end
