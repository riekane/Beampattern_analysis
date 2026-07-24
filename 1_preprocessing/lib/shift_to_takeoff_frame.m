function tc = shift_to_takeoff_frame(P, tp_xy, kind)
%SHIFT_TO_TAKEOFF_FRAME  Take-off-centred maze frame (180 deg about take-off).
%
%   tc = SHIFT_TO_TAKEOFF_FRAME(P, tp_xy)          % locations (default)
%   tc = SHIFT_TO_TAKEOFF_FRAME(P, tp_xy, 'loc')   % locations
%   tc = SHIFT_TO_TAKEOFF_FRAME(P, [],    'vec')   % direction vectors
%
% Maps room (Vicon-global) coordinates into the "take-off-centred" maze frame
% used for intuitive plotting: the take-off perch (marker 1) becomes the XY
% origin, the maze extends toward +Y as the bat flies deeper, and Z is
% unchanged. This is a 180 deg rotation about the vertical axis through the
% take-off perch -- a proper rotation, so physical left/right is preserved;
% only the world X/Y sign labels flip.
%
%   points  (kind='loc'):  x' = tpx - x ;  y' = tpy - y ;  z' = z
%   vectors (kind='vec'):  x' = -x       ;  y' = -y       ;  z' = z
%
% INPUT
%   P     - coordinates. Accepts an N-by-3 array (rows = points/samples,
%           cols = [x y z]), a single [x y z] as a 1x3 or 3x1 vector, or an
%           M-by-N-by-3 stack whose last dim is [x y z] (e.g. calls x mics x 3).
%           Column 3 (z) and any further columns pass through unchanged; NaNs
%           stay NaN.
%   tp_xy - [tpx tpy] take-off perch (marker 1), in the SAME UNITS as P.
%           Ignored (may be []) when kind = 'vec'.
%   kind  - 'loc' (default) for positions, 'vec' for direction vectors.
%
% LEFT/RIGHT: in the raw Vicon frame +X = the bat's LEFT arm (purple) and
% -X = the RIGHT arm (pink). Because this negates X, in the take-off-centred
% frame +X reads as the RIGHT arm even though the physical arm is unchanged --
% so judge left/right from these coordinates, not the old "+X = left" rule.
%
% Vicon+Avisoft beam-pattern pipeline, 2026.

    if nargin < 3 || isempty(kind), kind = 'loc'; end
    tc = P;
    if isempty(P) || ~isnumeric(P), return; end

    switch lower(kind)
        case 'loc'
            if nargin < 2 || numel(tp_xy) < 2
                error('shift_to_takeoff_frame:tp', ...
                    'tp_xy = [tpx tpy] is required for kind = ''loc''.');
            end
            ox = tp_xy(1); oy = tp_xy(2);
        case 'vec'
            ox = 0; oy = 0;   % direction vectors: pure sign flip, no pivot
        otherwise
            error('shift_to_takeoff_frame:kind', 'kind must be ''loc'' or ''vec''.');
    end

    if isvector(P) && numel(P) >= 2 && numel(P) <= 3
        tc(1) = ox - P(1);
        tc(2) = oy - P(2);
    elseif ndims(P) == 3 && size(P,3) >= 2
        tc(:,:,1) = ox - P(:,:,1);
        tc(:,:,2) = oy - P(:,:,2);
    elseif ismatrix(P) && size(P,2) >= 2
        tc(:,1) = ox - P(:,1);
        tc(:,2) = oy - P(:,2);
    else
        warning('shift_to_takeoff_frame:shape', ...
            'unhandled array shape [%s] -- returned unchanged.', num2str(size(P)));
    end
end
