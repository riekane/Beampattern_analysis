import numpy as np
from h5read import H5File
ZONE_KEYS=['approach','inside_y','past_y','arm_purple','arm_pink']
ZONE_LIST={'approach':([1,17,4,20,32],'EXCLUDE'),'inside_y':([2,3,18,19],'INCLUDE'),
           'past_y':([1,2,3,4,5,6,15,16,17,18,19,20,21,31,32],'INCLUDE'),
           'arm_purple':([6,21,7,5,10,24,8,2,26],'EXCLUDE'),'arm_pink':([31,16,11,29,13,28,27],'EXCLUDE')}
def open_trial(path):
    h=H5File(path)
    def read_refs(p):
        oh=h.get(p); msgs=h.obj_messages(oh); dims=dt=layout=None; filt=[]
        for mt,b in msgs:
            if mt==0x01: dims=h._dataspace(b)
            elif mt==0x03: dt=h._datatype(b)
            elif mt==0x08: layout=h._layout(b)
            elif mt==0x0b: filt=h._filters(b)
        npdt,elsz=dt
        if layout[0]=='contig': raw=h._rd(h.ub+layout[1],layout[2])
        elif layout[0]=='chunk': raw=h._read_chunked(layout,dims,npdt,elsz,filt).tobytes()
        else: raw=layout[1]
        return dims,np.frombuffer(raw,dtype='<u8')
    h.read_refs=read_refs
    return h
def build_L35(h,freq=35000.0):
    dims,addrs=h.read_refs('proc/call_psd_dB_comp_re20uPa_withbp')  # (nmic,ncall)
    _,addrf=h.read_refs('proc/call_freq_vec')
    nmic,ncall=dims
    L=np.full((nmic,ncall),np.nan)
    for i in range(nmic):
        for j in range(ncall):
            ad=int(addrs[i*ncall+j])
            if not ad: continue
            sp=h.read_dataset(h.ub+ad)
            if sp is None: continue
            sp=sp.ravel()
            fv=h.read_dataset(h.ub+int(addrf[i*ncall+j]))
            fv=fv.ravel() if fv is not None else None
            if fv is not None and fv.size==sp.size:
                fb=int(np.argmin(np.abs(fv-freq)))
            else:
                fb=int(round(freq/ (125000/ (sp.size-1)) )) if sp.size>1 else 0
                fb=min(fb,sp.size-1)
            L[i,j]=sp[fb]
    return L
def selected_rows(zone_id, mch):
    key=ZONE_KEYS[int(zone_id)-1]; lst,mode=ZONE_LIST[key]
    if mode=='INCLUDE': keep=np.isin(mch,lst)
    else: keep=~np.isin(mch,lst)
    return keep

def _orient(a,b,p): return (b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0])
def _seg_x(p1,p2,p3,p4):
    d1=_orient(p3,p4,p1); d2=_orient(p3,p4,p2); d3=_orient(p1,p2,p3); d4=_orient(p1,p2,p4)
    return ((d1>0 and d2<0) or (d1<0 and d2>0)) and ((d3>0 and d4<0) or (d3<0 and d4>0))
def los_select(bat_xy_mm, mics_xy_mm, walls_xy):
    segs=[]
    for W in walls_xy:
        for k in range(len(W)-1): segs.append((W[k],W[k+1]))
    vis=np.ones(len(mics_xy_mm),bool)
    for i,m in enumerate(mics_xy_mm):
        for (a,b) in segs:
            if _seg_x(bat_xy_mm,m,a,b): vis[i]=False; break
    return vis
def maze_walls(h):
    LW=np.asarray(h.read('maze/left_wall')); RW=np.asarray(h.read('maze/right_wall'))
    return [LW[:2,:].T, RW[:2,:].T]   # each 3x2 (mm)

from matplotlib.path import Path as _Path
def _wrap(x): return np.mod(x+np.pi,2*np.pi)-np.pi
def _hull(pts):
    p=sorted(map(tuple,pts)); 
    if len(p)<3: return np.array(p)
    def cross(o,a,b): return (a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0])
    lo=[]
    for q in p:
        while len(lo)>=2 and cross(lo[-2],lo[-1],q)<=0: lo.pop()
        lo.append(q)
    up=[]
    for q in reversed(p):
        while len(up)>=2 and cross(up[-2],up[-1],q)<=0: up.pop()
        up.append(q)
    return np.array(lo[:-1]+up[:-1])
def estbeam(mic_xyz,bat_xyz,dB,method='anchored',min_mics_fit=5,anchor_win_deg=40,grid_step_deg=1,rbf='linear'):
    dB=np.asarray(dB,float); mic_xyz=np.asarray(mic_xyz,float)
    ok=np.isfinite(dB)&np.all(np.isfinite(mic_xyz),1)
    if ok.sum()==0: return np.nan
    mic_xyz=mic_xyz[ok]; dB=dB[ok]; M=len(dB)
    vec=mic_xyz-np.asarray(bat_xyz,float)[None,:]
    az=np.arctan2(vec[:,1],vec[:,0]); el=np.arctan2(vec[:,2],np.hypot(vec[:,0],vec[:,1]))
    ip=int(np.argmax(dB)); paz=az[ip]; pel=el[ip]
    peak_az=np.degrees(paz)
    az0=np.arctan2(np.mean(np.sin(az)),np.mean(np.cos(az)))
    azc=_wrap(az-az0); pazc=_wrap(paz-az0)
    if M<min_mics_fit: return peak_az
    step=np.radians(grid_step_deg)
    aq=np.arange(azc.min(),azc.max()+1e-9,step); eq=np.arange(el.min(),el.max()+1e-9,step)
    if len(aq)<2 or len(eq)<2: return peak_az
    AZ,EL=np.meshgrid(aq,eq)
    X=np.vstack([azc,el])  # 2 x n
    const=(np.prod(X.max(1)-X.min(1))/M)**(1/2)
    if not np.isfinite(const) or const==0: const=1.0
    def phi(r):
        return r if rbf=='linear' else np.sqrt(1+ (r*r)/(const*const))
    # assemble
    D=np.sqrt(((X[:,:,None]-X[:,None,:])**2).sum(0))
    A=np.zeros((M+3,M+3)); A[:M,:M]=phi(D)
    P=np.column_stack([np.ones(M),azc,el]); A[:M,M:]=P; A[M:,:M]=P.T
    b=np.concatenate([dB,[0,0,0]])
    try: coeff=np.linalg.solve(A,b)
    except Exception: return peak_az
    Q=np.vstack([AZ.ravel(),EL.ravel()])  # 2 x G
    rQ=np.sqrt(((Q[:,:,None]-X[:,None,:])**2).sum(0))  # G x M
    vq=(phi(rQ)*coeff[:M]).sum(1)+coeff[M]+coeff[M+1]*Q[0]+coeff[M+2]*Q[1]
    vq=vq.reshape(AZ.shape)-dB.max()
    # convex mask
    H=_hull(np.column_stack([azc,el]))
    if len(H)>=3:
        inside=_Path(H).contains_points(np.column_stack([AZ.ravel(),EL.ravel()])).reshape(AZ.shape)
        vq=np.where(inside,vq,np.nan)
    if not np.isfinite(vq).any(): return peak_az
    win=np.radians(anchor_win_deg)
    if method=='peak2d':
        idx=np.nanargmax(vq); r,c=np.unravel_index(idx,vq.shape); beam_az=AZ[r,c]
    else:
        near=(np.abs(_wrap(AZ-pazc))<=win)&(np.abs(EL-pel)<=win)&np.isfinite(vq)
        if near.sum()<3: return peak_az
        vqm=np.where(near,vq,np.nan); idx=np.nanargmax(vqm); r,c=np.unravel_index(idx,vqm.shape); beam_az=AZ[r,c]
    return np.degrees(_wrap(beam_az+az0))
