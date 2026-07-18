function fig = plot_beam_map(pc, outcome, seg, opts)
%PLOT_BEAM_MAP  Top-down maze map with per-call beam rays + decision-axis trace.
%
%   fig = PLOT_BEAM_MAP(pc, outcome, seg)
%   fig = PLOT_BEAM_MAP(pc, outcome, seg, opts)
%
% Replaces the room-frame az-el heatmap / goal-relative rose, which are hard to
% read because the maze is NOT axis-aligned: from the take-off perch the goal
% sits at a room-frame azimuth of ~-123 deg, so "forward toward the goal" looks
% like "pointing backward" on any raw-azimuth plot. Drawing the beam as a RAY on
% the actual maze makes left/right/forward literal, and it generalises to a
% 2-perch (choice) maze with no code change: pass seg.lp_xyz as an N x 3 array
% and each landing perch is drawn and used for the decision axis.
%
% PANEL A (map): maze walls, start line, mics (numbered), take-off perch, every
%   landing perch, the bat->perch goal line, and one beam ray per call from the
%   bat's position, coloured by time-before-take-off.
% PANEL B (scan): the decision-axis coordinate vs time-before-take-off (x-axis
%   reversed so take-off is at the right). For >=2 perches this is a signed
%   "aimed-nearer-perch-1  vs  -perch-2" scalar; for a single perch it degrades
%   to the signed goal-relative azimuth (+ = to the bat's LEFT / +X).
%
% INPUT
%   pc      preflight_calls table (extract_preflight_calls) OR any call table
%           with: batx_mm, baty_mm, beam_az_deg, time_before_takeoff_s.
%   outcome classify_trial_outcome output (optional; used only for a title tag).
%   seg     segment_flight output: needs .tp_xyz (1x3) and .lp_xyz (N x 3).
%   opts    .maze     maze struct (walls) -- else tries seg.maze, else skipped
%           .mic_xy   M x 2 mic XY (mm)   -- else mics not drawn
%           .mic_num  M x 1 mic numbers   -- labels for mic_xy
%           .ray_len_mm (400) .save_dir ('') .tag ('') .visible ('on')
%           .traj     T x 2/3 trajectory (mm) to draw faintly (optional)
%
% OUTPUT: fig, figure handle.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

if nargin < 2, outcome = []; end
if nargin < 4 || isempty(opts), opts = struct(); end
save_dir = local_getdef(opts,'save_dir','');
tag      = local_getdef(opts,'tag','beam_map');
vis      = local_getdef(opts,'visible','on');
ray_len  = local_getdef(opts,'ray_len_mm',400);
maze     = local_getdef(opts,'maze',[]);
if isempty(maze) && isfield(seg,'maze'), maze = seg.maze; end
mic_xy   = local_getdef(opts,'mic_xy',[]);
mic_num  = local_getdef(opts,'mic_num',[]);
traj     = local_getdef(opts,'traj',[]);

% ---- pull call data ----
bx = pc.batx_mm(:);  by = pc.baty_mm(:);
az = pc.beam_az_deg(:);
if any(strcmp('time_before_takeoff_s', pc.Properties.VariableNames))
    tb = pc.time_before_takeoff_s(:);
else
    tb = (1:numel(bx))';   % no timing -> colour by index
end
ok = isfinite(bx) & isfinite(by) & isfinite(az);
bx = bx(ok); by = by(ok); az = az(ok); tb = tb(ok);

tp = seg.tp_xyz(1,:);
LP = seg.lp_xyz;                 % N x 3
nLP = size(LP,1);

fig = figure('Visible',vis,'Position',[80 80 1180 540],'Color','w');

% =================== PANEL A : top-down map ===================
axA = subplot(1,2,1); hold(axA,'on'); axis(axA,'equal');
if ~isempty(maze)
    if isfield(maze,'left_wall'),  plot(axA, maze.left_wall(:,1),  maze.left_wall(:,2),  'k-','LineWidth',1.6); end
    if isfield(maze,'right_wall'), plot(axA, maze.right_wall(:,1), maze.right_wall(:,2), 'k-','LineWidth',1.6); end
    if isfield(maze,'start_line'), plot(axA, maze.start_line(:,1), maze.start_line(:,2), 'k:','LineWidth',1.0); end
end
if ~isempty(traj)
    plot(axA, traj(:,1), traj(:,2), '-', 'Color',[.8 .8 .85],'LineWidth',1);
end
if ~isempty(mic_xy)
    plot(axA, mic_xy(:,1), mic_xy(:,2), '^', 'Color',[.55 .55 .55], ...
        'MarkerSize',4,'MarkerFaceColor',[.88 .88 .88]);
    if ~isempty(mic_num)
        for i = 1:size(mic_xy,1)
            text(axA, mic_xy(i,1)+35, mic_xy(i,2), sprintf('%d',mic_num(i)), ...
                'Color',[.6 .6 .6],'FontSize',6);
        end
    end
end
% perches
plot(axA, tp(1), tp(2), 'ks','MarkerSize',11,'MarkerFaceColor',[1 .85 .2],'LineWidth',1);
text(axA, tp(1)+60, tp(2), 'take-off','FontSize',8);
for k = 1:nLP
    plot(axA, LP(k,1), LP(k,2), 'p','MarkerSize',16, ...
        'MarkerFaceColor',[.3 .8 .45],'MarkerEdgeColor','k');
    text(axA, LP(k,1)+60, LP(k,2), sprintf('landing %d',k),'FontSize',8);
end
% goal line take-off -> perch 1 (reference "forward")
gb = atan2(LP(1,2)-tp(2), LP(1,1)-tp(1));
plot(axA, [tp(1) tp(1)+2*ray_len*cos(gb)], [tp(2) tp(2)+2*ray_len*sin(gb)], ...
    '--','Color',[.3 .8 .45],'LineWidth',1);
% beam rays coloured by time-before-take-off
cmap = parula(256);
cmn = min(tb); cmx = max(tb);
for i = 1:numel(bx)
    a  = az(i)*pi/180;
    if cmx > cmn, f = (tb(i)-cmn)/(cmx-cmn); else, f = 0.5; end
    col = cmap(min(max(round(1+255*f),1),256),:);
    plot(axA, [bx(i) bx(i)+ray_len*cos(a)], [by(i) by(i)+ray_len*sin(a)], ...
        '-','Color',col,'LineWidth',1);
    plot(axA, bx(i), by(i), '.','Color',col,'MarkerSize',7);
end
colormap(axA, cmap);
if cmx > cmn, set(axA,'CLim',[cmn cmx]); end
cb = colorbar(axA); ylabel(cb,'time before take-off (s)');
grid(axA,'on'); box(axA,'on');
xlabel(axA,'X (mm)   (+X = left arm)'); ylabel(axA,'Y (mm)');
title(axA, sprintf('%s   beam rays (n=%d)   goal bearing = %.0f\\circ', ...
    tag, numel(bx), gb*180/pi), 'Interpreter','tex');

% =================== PANEL B : decision-axis scan ===================
axB = subplot(1,2,2); hold(axB,'on');
dec = local_decision(bx, by, az, LP);
if cmx > cmn
    scatter(axB, tb, dec, 26, tb, 'filled');
else
    plot(axB, tb, dec, 'o-','Color',[.2 .3 .7],'MarkerFaceColor',[.2 .3 .7]);
end
plot(axB, [min(tb) max(tb)], [0 0], 'k-');    % zero reference (portable; not yline)
set(axB,'XDir','reverse');
xlabel(axB,'time before take-off (s)');
if nLP >= 2
    ylabel(axB,'decision axis   (+ = aimed nearer landing 1)');
else
    ylabel(axB,'goal-relative azimuth (\circ)   (+ = bat''s LEFT / +X)');
end
grid(axB,'on'); box(axB,'on'); colormap(axB, cmap);
title(axB,'pre-flight scan (right edge = take-off)');

% ---- save ----
if ~isempty(save_dir)
    if ~exist(save_dir,'dir'), mkdir(save_dir); end
    fn = fullfile(save_dir, sprintf('%s_beam_map.png', tag));
    try, exportgraphics(fig, fn, 'Resolution',150); catch, saveas(fig, fn); end
    fprintf('  saved %s\n', fn);
end
end

% ===================== helpers =====================
function v = local_getdef(s,f,d)
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

function dec = local_decision(bx, by, az, LP)
% Signed decision-axis coordinate per call.
%  N>=2 perches: (|off to perch2| - |off to perch1|) in deg. >0 => aimed nearer
%                perch 1; <0 => nearer perch 2. Symmetric, scales to N by taking
%                the two most divergent perches (1 and end).
%  N==1 perch : signed goal-relative azimuth, + = bat's LEFT (+X) of the
%                bat->perch bearing.
    n = numel(az);
    dec = nan(n,1);
    if size(LP,1) >= 2
        A = LP(1,:); B = LP(end,:);
        for i = 1:n
            ba = atan2(A(2)-by(i), A(1)-bx(i))*180/pi;
            bb = atan2(B(2)-by(i), B(1)-bx(i))*180/pi;
            oa = abs(local_wrap180(az(i)-ba));
            ob = abs(local_wrap180(az(i)-bb));
            dec(i) = ob - oa;
        end
    else
        for i = 1:n
            bg = atan2(LP(1,2)-by(i), LP(1,1)-bx(i))*180/pi;
            dec(i) = local_wrap180(az(i)-bg);
        end
    end
end

function a = local_wrap180(a)
    a = mod(a+180,360)-180;
end
