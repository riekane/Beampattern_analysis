function plot_mic_selection_qc(bat_pos_file, mic_pos_file, save_png)
%PLOT_MIC_SELECTION_QC  Visual check of the Y-maze zoning + per-position mic sets.
%
%   plot_mic_selection_qc(bat_pos_file)
%   plot_mic_selection_qc(bat_pos_file, mic_pos_file)
%   plot_mic_selection_qc(bat_pos_file, mic_pos_file, save_png)
%
% Draws, in the XY (top) view:
%   * the five zones as FILLED regions (classify a dense grid), so you can see
%     the exact spatial extent of each zone;
%   * the maze walls, start line and tips-of-Y line, and the two arm X-lines;
%   * the bat trajectory (thin line) and the mics (labelled squares) if given.
%
% INPUT
%   bat_pos_file - a bat_pos.mat from the position pipeline (embeds .maze).
%   mic_pos_file - (optional) mic_pos_<date>.mat or .csv (to plot mics).
%   save_png     - (optional) path to save a PNG; '' = don't save (default).

if nargin < 2, mic_pos_file = ''; end
if nargin < 3, save_png = ''; end

bp = load(bat_pos_file);
track = bp.bat_pos; if iscell(track), track = track{1}; end
maze  = bp.maze;
zones = build_maze_zones(maze);
all_mic_nums = 1:32;

names  = zones.zone_names;    % {pre-maze entrance, inside_y, past_y, arm_purple, arm_pink}
colors = [0.56 0.74 1.00;     % 1 pre-maze entrance    blue
          0.50 0.82 0.50;     % 2 maze pre-junction    green
          1.00 0.82 0.50;     % 3 maze past-junction     yellow
          0.79 0.64 0.90;     % 4 left arm  purple (+X)
          0.96 0.65 0.69];    % 5 right arm   pink   (-X)

figure('Color','w','Position',[60 60 950 950]); hold on;

% ---- filled zone regions via grid classification ----
pad = 400;
xg = linspace(min(track(:,1))-pad, max(track(:,1))+pad, 400);
yg = linspace(min(track(:,2))-pad, max(track(:,2))+pad, 400);
[XX,YY] = meshgrid(xg,yg);
ZZ = zeros(size(XX));
for i = 1:numel(XX)
    [~, ZZ(i)] = select_mics_by_position([XX(i) YY(i)], zones, all_mic_nums);
end
colormap(colors);
pcolor(XX,YY,ZZ); shading flat; caxis([0.5 5.5]); alpha(0.65);

% ---- boundary lines ----
xr = [min(xg) max(xg)];
ly = @(p1,p2,x) p1(2) + (p2(2)-p1(2))*(x-p1(1))/(p2(1)-p1(1)+eps);
plot(xr,[ly(zones.start_p1,zones.start_p2,xr(1)) ly(zones.start_p1,zones.start_p2,xr(2))], ...
     'k--','LineWidth',1.5,'DisplayName','start line');
plot(xr,[ly(zones.tips_p1,zones.tips_p2,xr(1)) ly(zones.tips_p1,zones.tips_p2,xr(2))], ...
     '--','Color',[.4 .4 .4],'LineWidth',1.5,'DisplayName','tips of Y');
% zone-3 (yellow) sides: maze walls down to each maze_exit, then VERTICAL at the
% maze_exit X below the exit line
yb = min(yg);
plot([zones.wallR(3,1) zones.wallR(3,1)],[zones.wallR(3,2) yb],':','Color',[.7 .1 .1],'LineWidth',1.5,'DisplayName','-X boundary below exit (X=maze\_exit\_right)');
plot([zones.wallL(3,1) zones.wallL(3,1)],[zones.wallL(3,2) yb],':','Color',[.42 .1 .55],'LineWidth',1.5,'DisplayName','+X boundary below exit (X=maze\_exit\_left)');

% ---- maze walls ----
plot(maze.left_wall(:,1),  maze.left_wall(:,2),  '-o','Color','k','LineWidth',2.5,'MarkerSize',5,'HandleVisibility','off');
plot(maze.right_wall(:,1), maze.right_wall(:,2), '-o','Color','k','LineWidth',2.5,'MarkerSize',5,'HandleVisibility','off');

% ---- trajectory ----
plot(track(:,1),track(:,2),'-','Color','k','LineWidth',0.8,'DisplayName','bat path');

% ---- take-off perch ----
if isfield(maze,'takeoff_perch') && ~isempty(maze.takeoff_perch)
    scatter(maze.takeoff_perch(1),maze.takeoff_perch(2),260,'p', ...
            'MarkerFaceColor',[1 .84 0],'MarkerEdgeColor','k','DisplayName','take-off perch');
end

% ---- mics ----
if ~isempty(mic_pos_file)
    [mx,my,mnum] = local_load_mics(mic_pos_file);
    scatter(mx,my,44,'ws','filled','MarkerEdgeColor','k','HandleVisibility','off');
    for i = 1:numel(mnum)
        text(mx(i),my(i),num2str(mnum(i)),'FontSize',7.5,'HorizontalAlignment','center');
    end
end

% ---- legend proxies for the filled zones ----
for z = 1:5
    patch(NaN,NaN,colors(z,:),'DisplayName',sprintf('zone %d %s',z,names{z}));
end

axis equal; grid on;
xlabel('X (mm)'); ylabel('Y (mm)');
title('maze zoning','Interpreter','none');
legend('Location','eastoutside','FontSize',8);

% ---- report ----
zid = zeros(size(track,1),1);
for i = 1:size(track,1)
    [~, zid(i)] = select_mics_by_position(track(i,1:2), zones, all_mic_nums);
end
fprintf('Frames per zone:');
for z = 1:5, fprintf('  %s=%d', names{z}, sum(zid==z)); end
fprintf('  (no-track=%d)\n', sum(zid==0));

if ~isempty(save_png)
    saveas(gcf, save_png); fprintf('Saved %s\n', save_png);
end
end

function [x,y,num] = local_load_mics(mic_pos_file)
    [~,~,ext] = fileparts(mic_pos_file);
    if strcmpi(ext,'.csv')
        T = readtable(mic_pos_file);
        x = T.pos_X_mm; y = T.pos_Y_mm; nm = T.mic_name;
    else
        S = load(mic_pos_file);
        x = S.mic_pos(:,1); y = S.mic_pos(:,2); nm = S.mic_names;
    end
    nm = cellstr(nm);
    num = nan(numel(nm),1);
    for i = 1:numel(nm)
        tok = regexp(nm{i},'(\d+)\s*$','tokens','once');
        if ~isempty(tok), num(i) = str2double(tok{1}); end
    end
    keep = ~isnan(x) & ~isnan(num);
    x = x(keep); y = y(keep); num = num(keep);
end
