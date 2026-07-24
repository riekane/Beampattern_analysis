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

%   Written by Rie Kaneko on 7/14/2026

if nargin < 3 || isempty(arrow_len_m), arrow_len_m = 0.3; end
if nargin < 4, save_png = ''; end   % '' -> auto path (bat's \plot folder); 'none' -> don't save
bpp = load(bp_proc_file);

if nargin < 2 || isempty(out)
    out.beam_aim_az_el_deg = bpp.proc.beam_aim_az_el_deg;
    out.beam_aim_method    = bpp.proc.beam_aim_method;
end

% ---- draw in the TAKE-OFF-CENTRED maze frame (take-off -> (0,0), deeper +Y) ----
% Prefer the stored takeoff_centered.* (added by bp_proc stage 1); compute it on
% the fly for older files that predate it. Raw fields are untouched -- we only
% swap the local copies used for drawing, and rotate the beam azimuth by +180
% deg to match. With no take-off perch available it stays in the raw frame.
az_offset_deg = 0; frame_tag = '(raw Vicon frame)';
if ~isfield(bpp,'takeoff_centered') && exist('add_takeoff_centered_coords','file')
    try, bpp = add_takeoff_centered_coords(bpp); catch, end
end
if isfield(bpp,'takeoff_centered')
    TC = bpp.takeoff_centered;
    if isfield(TC,'mic_loc')         && ~isempty(TC.mic_loc),         bpp.mic_loc = TC.mic_loc; end
    if isfield(TC,'bat_loc_at_call') && ~isempty(TC.bat_loc_at_call), bpp.proc.bat_loc_at_call = TC.bat_loc_at_call; end
    if isfield(bpp,'track') && isfield(TC,'track')
        if isfield(TC.track,'track_interp') && ~isempty(TC.track.track_interp), bpp.track.track_interp = TC.track.track_interp; end
        if isfield(TC.track,'track_tail')   && ~isempty(TC.track.track_tail),   bpp.track.track_tail   = TC.track.track_tail;   end
    end
    if isfield(bpp,'maze') && isfield(TC,'maze')
        for mf = {'left_wall','right_wall','start_line','takeoff_perch','landing_perch'}
            if isfield(TC.maze,mf{1}) && ~isempty(TC.maze.(mf{1})), bpp.maze.(mf{1}) = TC.maze.(mf{1}); end
        end
    end
    if isfield(TC,'perch_pos')   && ~isempty(TC.perch_pos),   bpp.perch_pos   = TC.perch_pos;   end
    if isfield(TC,'tp_position') && ~isempty(TC.tp_position), bpp.tp_position = TC.tp_position; end
    if isfield(TC,'lp_position') && ~isempty(TC.lp_position), bpp.lp_position = TC.lp_position; end
    az_offset_deg = 180; frame_tag = '(take-off-centred: +X = right arm, +Y = deeper)';
end

bat = bpp.proc.bat_loc_at_call;                 % calls x 3 (metres)
mic = bpp.mic_loc;                              % mics x 3
az  = deg2rad(out.beam_aim_az_el_deg(:,1) + az_offset_deg);
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
trajcol = [0 0 0];
if isfield(bpp,'track') && isfield(bpp.track,'track_interp') && ~isempty(bpp.track.track_interp)
    T = bpp.track.track_interp;                          % 1 ms track (metres)
    v = ~isnan(T(:,1));
    d = diff([0; double(v); 0]);
    runS = find(d==1); runE = find(d==-1)-1;             % contiguous tracked runs
    hs = gobjects(0); hd = gobjects(0);
    for k = 1:numel(runS)                                % solid = tracked
        hh = plot(T(runS(k):runE(k),1), T(runS(k):runE(k),2), '-', ...
                  'Color',trajcol, 'LineWidth',2.5);
        if isempty(hs), hs = hh; end
    end
    for k = 1:numel(runS)-1                              % dashed = interpolated bridge
        hh = plot([T(runE(k),1) T(runS(k+1),1)], [T(runE(k),2) T(runS(k+1),2)], '--', ...
                  'Color',trajcol, 'LineWidth',2);
        if isempty(hd), hd = hh; end
    end
    if ~isempty(hs), traj_h(end+1) = hs; traj_l{end+1} = 'flight path'; end
    if ~isempty(hd), traj_h(end+1) = hd; traj_l{end+1} = 'interpolated gap'; end
else
    plot(bat(:,1), bat(:,2), '-', 'Color',trajcol, 'LineWidth',2.5);  % fallback: connect calls
end

% post-TTL landing tail: the ~0.1 s of Vicon AFTER the audio ended (trimmed off
% track_interp), where the bat usually touches down. Drawn contiguous with the
% path (same thick black) + a touchdown dot, so a successful landing is obvious.
% The beam-aim arrows (audio overlay) are unchanged -- they stay on the calls.
if isfield(bpp,'track') && isfield(bpp.track,'track_tail') && ~isempty(bpp.track.track_tail)
    Tt = bpp.track.track_tail; vt = ~isnan(Tt(:,1));
    if any(vt)
        ht = plot(Tt(vt,1), Tt(vt,2), '-', 'Color',trajcol, 'LineWidth',2.5);
        lv = find(vt,1,'last');
        plot(Tt(lv,1), Tt(lv,2), 'o', 'MarkerSize',10, 'MarkerFaceColor','k','MarkerEdgeColor','k');
        % landing tail drawn but kept OUT of the legend (not a separate series)
    end
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
% perches: prefer the Vicon-tracked position, else the JSON-labelled maze perch.
tp = local_perch(bpp,'takeoff_perch','tp_position');
LP = local_landing_list(bpp);                   % Nx3 mm, ALL landing perches
if ~isempty(tp)
    perch_h(end+1) = scatter(tp(1)*s, tp(2)*s, 400,'o', ...
            'MarkerFaceColor',[1 .84 0],'MarkerEdgeColor','k','LineWidth',1.5);
    perch_l{end+1} = 'take-off perch';
end
lp_cols = {[0 .70 .90],[.93 .53 .18],[.47 .67 .19],[.30 .30 .90]};
for iL = 1:size(LP,1)
    cc = lp_cols{mod(iL-1,numel(lp_cols))+1};
    perch_h(end+1) = scatter(LP(iL,1)*s, LP(iL,2)*s, 360,'o', ...
            'MarkerFaceColor',cc,'MarkerEdgeColor','k','LineWidth',1.5); %#ok<AGROW>
    if size(LP,1) > 1
        perch_l{end+1} = sprintf('landing perch %d', iL); %#ok<AGROW>
    else
        perch_l{end+1} = 'landing perch';                %#ok<AGROW>
    end
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
title(['Beam-aim (top view)  ' frame_tag]);
if any(meth == 2)     % peak-mic fallback actually used -> show both beam-aim types
    h1 = plot(nan,nan,'-','Color',blue,'LineWidth',2);
    h2 = plot(nan,nan,'-','Color',red,'LineWidth',2);
    aim_h = [h1 h2];
    aim_l = {'beam aim (interp + Gaussian fit)','beam aim (peak-mic fallback)'};
else                  % all calls used interp+fit -> a single "beam aim" entry
    aim_h = plot(nan,nan,'-','Color',blue,'LineWidth',2);
    aim_l = {'beam aim'};
end
legend([aim_h traj_h perch_h], [aim_l traj_l perch_l], 'Location','best');
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
    [figdir, figbase] = fileparts(save_png);
    save_fig = fullfile(figdir, [figbase '.fig']);   % MATLAB .fig, same name & location as the .png
    savefig(gcf, save_fig);
    fprintf('Saved QC plot %s (+ %s)\n', save_png, [figbase '.fig']);
end
end

function LP = local_landing_list(bpp)
% All landing-perch marker-1 positions (Nx3 mm). Prefers perch_pos.landing (>=1
% perch, carried from the bat_pos file); falls back to the single maze
% landing_perch / Vicon lp_position for older bp_proc files.
    LP = [];
    if isfield(bpp,'perch_pos') && isstruct(bpp.perch_pos) && isfield(bpp.perch_pos,'landing') ...
            && ~isempty(bpp.perch_pos.landing)
        P = bpp.perch_pos.landing;
        for k = 1:numel(P)
            if isfield(P(k),'marker1') && numel(P(k).marker1) >= 3 && ~any(isnan(P(k).marker1(1:3)))
                LP(end+1,:) = P(k).marker1(1:3); %#ok<AGROW>
            end
        end
    end
    if isempty(LP)
        p = [];
        if isfield(bpp,'lp_position') && ~isempty(bpp.lp_position)
            p = bpp.lp_position;
        elseif isfield(bpp,'maze') && isstruct(bpp.maze) && isfield(bpp.maze,'landing_perch') ...
                && ~isempty(bpp.maze.landing_perch)
            p = bpp.maze.landing_perch;
        end
        if ~isempty(p), LP = p(1:3); end
    end
end

function p = local_perch(bpp, maze_field, vicon_field)
% Resolve a perch [x y z] (mm): prefer the Vicon-tracked perch position carried
% in the bp_proc file, else the JSON-labelled maze perch. Empty if neither.
    p = [];
    if isfield(bpp,vicon_field) && ~isempty(bpp.(vicon_field))
        p = bpp.(vicon_field);
    elseif isfield(bpp,'maze') && isstruct(bpp.maze) && isfield(bpp.maze,maze_field) ...
            && ~isempty(bpp.maze.(maze_field))
        p = bpp.maze.(maze_field);
    end
end
