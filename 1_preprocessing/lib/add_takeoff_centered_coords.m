function data = add_takeoff_centered_coords(data)
%ADD_TAKEOFF_CENTERED_COORDS  Add take-off-centred copies of the room-frame
% locations/vectors in a bp_proc DATA struct, WITHOUT touching the originals.
%
%   data = ADD_TAKEOFF_CENTERED_COORDS(data)
%
% Adds ONE new field, data.takeoff_centered, holding shifted copies of every
% plotted location/vector: mic_loc, mic_vec, proc.bat_loc_at_call, the track
% arrays, the maze walls/start-line/perches, tp/lp_position, perch_pos, and the
% head aim/normal + mic_to_bat direction vectors. Every raw field is left
% exactly as it was, so existing analysis is unaffected; the shifted copies are
% purely for intuitive plotting/interpretation.
%
% FRAME: 180 deg rotation about the vertical axis through the take-off perch
% (marker 1) -- take-off becomes the XY origin, the maze extends toward +Y as
% the bat flies deeper, Z unchanged (see shift_to_takeoff_frame.m):
%   locations : x' = tpx - x ; y' = tpy - y ; z' = z
%   vectors   : x' = -x       ; y' = -y      ; z' = z
% Pivot (mm) is read from perch_pos.takeoff.marker1, else tp_position, else
% maze.takeoff_perch.
%
% NOTE (left/right): raw Vicon uses +X = LEFT arm (purple) / -X = RIGHT arm
% (pink). This negates X, so in the take-off-centred frame +X reads as the
% RIGHT arm. Physical left/right is unchanged -- only the sign label flips --
% so read left/right off these coords, not the old +X=left rule.
%
% Vicon+Avisoft beam-pattern pipeline, 2026.

    tp_mm = local_takeoff_xy_mm(data);
    if isempty(tp_mm)
        warning('add_takeoff_centered_coords:noTakeoff', ...
            ['No take-off perch found (perch_pos.takeoff.marker1 / tp_position / ' ...
             'maze.takeoff_perch) -- take-off-centred coords NOT added.']);
        return;
    end
    tp_m = tp_mm / 1000;

    tc = struct();
    tc.pivot_mm = tp_mm;
    tc.pivot_m  = tp_m;
    tc.info = ['Take-off-centred maze frame (180 deg about take-off marker 1): ' ...
        'loc x''=tpx-x, y''=tpy-y, z''=z; vec x''=-x, y''=-y, z''=z. ' ...
        'Take-off -> (0,0), deeper-in-maze -> +Y. X sign flips vs raw Vicon, so ' ...
        'here +X = RIGHT arm (raw had +X = LEFT); physical left/right unchanged.'];

    % ---------- metre-unit fields ----------
    tc.mic_loc         = local_loc(get_field(data,'mic_loc'),                 tp_m);
    tc.mic_vec         = local_vec(get_field(data,'mic_vec'));
    tc.bat_loc_at_call = local_loc(get_field(data,'proc','bat_loc_at_call'),  tp_m);
    tc.mic_to_bat_vec  = local_vec(get_field(data,'proc','mic_to_bat_vec'));
    for f = {'marked_pos','track_raw','track_smooth','track_interp','track_tail'}
        tc.track.(f{1}) = local_loc(get_field(data,'track',f{1}), tp_m);
    end
    tc.head_aim_int    = local_vec(get_field(data,'head_aim','head_aim_int'));
    tc.head_normal_int = local_vec(get_field(data,'head_normal','head_normal_int'));

    % ---------- millimetre-unit fields ----------
    for f = {'left_wall','right_wall','start_line','takeoff_perch','landing_perch'}
        tc.maze.(f{1}) = local_loc(get_field(data,'maze',f{1}), tp_mm);
    end
    tc.tp_position = local_loc(get_field(data,'tp_position'), tp_mm);
    tc.lp_position = local_loc(get_field(data,'lp_position'), tp_mm);
    if isfield(data,'perch_pos') && isstruct(data.perch_pos)
        tc.perch_pos = local_shift_perch_pos(data.perch_pos, tp_mm);
    end

    data.takeoff_centered = tc;
    fprintf(['Added take-off-centred coords (data.takeoff_centered): pivot ' ...
        '[%.1f %.1f] mm -> (0,0); deeper-in-maze = +Y.\n'], tp_mm(1), tp_mm(2));
end

% ===================== helpers =====================
function v = get_field(s, varargin)
% Nested getfield: returns [] if any level is missing or empty.
    v = [];
    for i = 1:numel(varargin)
        if ~isstruct(s) || ~isfield(s, varargin{i}) || isempty(s.(varargin{i}))
            return;
        end
        s = s.(varargin{i});
    end
    v = s;
end

function A = local_loc(A, tp_xy)
% Shift a location array (units must match tp_xy). Non-coordinate -> [].
    if isempty(A) || ~isnumeric(A) || numel(A) < 3
        A = []; return;
    end
    A = shift_to_takeoff_frame(A, tp_xy, 'loc');
end

function A = local_vec(A)
% Shift a direction-vector array. Non-coordinate -> [].
    if isempty(A) || ~isnumeric(A) || numel(A) < 3
        A = []; return;
    end
    A = shift_to_takeoff_frame(A, [0 0], 'vec');
end

function tp = local_takeoff_xy_mm(data)
% Take-off perch (marker 1) [tpx tpy] in mm; [] if none found.
    tp = [];
    pp = get_field(data,'perch_pos');
    if isstruct(pp) && isfield(pp,'takeoff') && ~isempty(pp.takeoff)
        T = pp.takeoff(1);
        if isfield(T,'marker1') && numel(T.marker1) >= 2 && ~any(isnan(T.marker1(1:2)))
            tp = [T.marker1(1) T.marker1(2)]; return;
        end
    end
    v = get_field(data,'tp_position');
    if numel(v) >= 2 && ~any(isnan(v(1:2))), tp = [v(1) v(2)]; return; end
    v = get_field(data,'maze','takeoff_perch');
    if numel(v) >= 2 && ~any(isnan(v(1:2))), tp = [v(1) v(2)]; return; end
end

function pp = local_shift_perch_pos(pp, tp_mm)
% Shift .pos and .marker1 of every take-off/landing perch entry (mm).
    for g = {'takeoff','landing'}
        gname = g{1};
        if isfield(pp, gname) && ~isempty(pp.(gname))
            for k = 1:numel(pp.(gname))
                if isfield(pp.(gname)(k),'pos') && numel(pp.(gname)(k).pos) >= 3
                    pp.(gname)(k).pos = shift_to_takeoff_frame(pp.(gname)(k).pos, tp_mm, 'loc');
                end
                if isfield(pp.(gname)(k),'marker1') && numel(pp.(gname)(k).marker1) >= 3
                    pp.(gname)(k).marker1 = shift_to_takeoff_frame(pp.(gname)(k).marker1, tp_mm, 'loc');
                end
            end
        end
    end
end
