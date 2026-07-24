"""Minimal HDF5 (MATLAB v7.3) numeric reader. Pure python + numpy.
Supports: superblock v0/v2, v1 object headers w/ continuation,
old-style symbol-table groups AND new-style link messages,
contiguous + chunked(v1 btree) datasets, deflate/shuffle/fletcher filters,
fixed-point + float datatypes. Enough for MATLAB -v7.3 numeric arrays."""
import struct, zlib, numpy as np

class H5File:
    def __init__(self, path):
        self.f=open(path,'rb'); self.d=None
        self._map()
    def _rd(self,off,n):
        self.f.seek(off); return self.f.read(n)
    def _map(self):
        # find userblock: signature at 0,512,1024,...
        sig=b'\x89HDF\r\n\x1a\n'; ub=0
        while ub< (1<<20):
            if self._rd(ub,8)==sig: break
            ub=512 if ub==0 else ub*2
        self.ub=ub
        ver=self._rd(ub+8,1)[0]
        if ver in (0,1):
            hdr=self._rd(ub+8,56+32)
            self.osz=hdr[5]; self.lsz=hdr[6]
            # base at sb offset 24; root symbol-table-entry at 24 + 4*osz
            q=24+4*self.osz
            # symbol table entry: link name off(osz), obj header addr(osz)
            self.root_oh=int.from_bytes(self._rd(ub+q+self.osz,self.osz),'little')
        elif ver in (2,3):
            hdr=self._rd(ub+9,3); self.osz=hdr[0]; self.lsz=hdr[1]
            q=ub+12
            self.root_oh=int.from_bytes(self._rd(q+3*self.osz,self.osz),'little')
        else: raise ValueError("sb ver %d"%ver)
    def addr(self,rel):
        return None if rel==int.from_bytes(b'\xff'*self.osz,'little') else self.ub+rel
    # -------- object header --------
    def obj_messages(self, oh_abs):
        msgs=[]; self._read_oh(oh_abs,msgs); return msgs
    def _read_oh(self, oh_abs, msgs):
        first=self._rd(oh_abs,16)
        if first[:4]==b'OHDR':
            self._read_oh_v2(oh_abs,msgs); return
        ver=first[0]
        nmsg=struct.unpack('<H',first[2:4])[0]
        hsz=struct.unpack('<I',first[8:12])[0]
        self._parse_msgs(oh_abs+16, hsz, msgs, v2=False)
    def _parse_msgs(self, start, size, msgs, v2, creorder=False):
        p=start; end=start+size
        while p < end-1:
            mtype=struct.unpack('<H',self._rd(p,2))[0]
            msz=struct.unpack('<H',self._rd(p+2,2))[0]
            flags=self._rd(p+4,1)[0]
            body_off=p+8
            body=self._rd(body_off,msz)
            if mtype==0x10: # continuation
                coff=int.from_bytes(body[:self.osz],'little')
                clen=int.from_bytes(body[self.osz:self.osz+self.lsz],'little')
                self._parse_msgs(self.ub+coff, clen, msgs, v2=False)
            else:
                msgs.append((mtype,body))
            p=body_off+msz
    def _read_oh_v2(self, oh_abs, msgs):
        d=self._rd(oh_abs,6); ver=d[4]; flags=d[5]
        p=oh_abs+6
        if flags&0x20: p+=4
        if flags&0x10: p+=4
        szc=flags&0x3
        chunk_len=int.from_bytes(self._rd(p, 1<<szc),'little'); p+=(1<<szc)
        self._parse_msgs_v2(p, chunk_len, msgs, flags)
    def _parse_msgs_v2(self, start, size, msgs, ohflags):
        p=start; end=start+size-4
        while p < end:
            mtype=self._rd(p,1)[0]; msz=struct.unpack('<H',self._rd(p+1,2))[0]; fl=self._rd(p+3,1)[0]
            hdr=4+(2 if (ohflags&0x4) else 0)
            body=self._rd(p+hdr,msz)
            if mtype==0x10:
                coff=int.from_bytes(body[:self.osz],'little')
                clen=int.from_bytes(body[self.osz:self.osz+self.lsz],'little')
                self._parse_msgs_v2(self.ub+coff+4, clen-4, msgs, ohflags)
            else:
                msgs.append((mtype,body))
            p=p+hdr+msz
    # -------- groups --------
    def group_members(self, oh_abs):
        msgs=self.obj_messages(oh_abs)
        members={}
        for mt,body in msgs:
            if mt==0x11:
                bt=int.from_bytes(body[:self.osz],'little')
                heap=int.from_bytes(body[self.osz:2*self.osz],'little')
                self._walk_group_btree(self.ub+bt, self.ub+heap, members)
            elif mt==0x06:
                name,addr=self._parse_link(body)
                if name is not None: members[name]=addr
            elif mt==0x02:
                pass
        return members
    def _heap_name(self, heap_abs, nameoff):
        hd=self._rd(heap_abs,8+2*self.lsz+self.osz)
        dataseg=int.from_bytes(hd[8+2*self.lsz:8+2*self.lsz+self.osz],'little')
        raw=self._rd(self.ub+dataseg+nameoff,256)
        return raw.split(b'\x00',1)[0].decode('ascii','replace')
    def _walk_group_btree(self, bt_abs, heap_abs, members):
        sig=self._rd(bt_abs,4)
        if sig!=b'TREE': return
        d=self._rd(bt_abs,24)
        node_type=d[4]; node_level=d[5]
        entries=struct.unpack('<H',d[6:8])[0]
        p=bt_abs+8+2*self.osz
        p+=self.lsz
        for i in range(entries):
            child=int.from_bytes(self._rd(p,self.osz),'little'); p+=self.osz
            p+=self.lsz
            if node_level>0:
                self._walk_group_btree(self.ub+child, heap_abs, members)
            else:
                self._read_snod(self.ub+child, heap_abs, members)
    def _read_snod(self, snod_abs, heap_abs, members):
        d=self._rd(snod_abs,8)
        if d[:4]!=b'SNOD': return
        nsym=struct.unpack('<H',d[6:8])[0]
        p=snod_abs+8
        esize=2*self.osz+4+4+16
        for i in range(nsym):
            e=self._rd(p,esize)
            nameoff=int.from_bytes(e[:self.osz],'little')
            oh=int.from_bytes(e[self.osz:2*self.osz],'little')
            nm=self._heap_name(heap_abs,nameoff)
            members[nm]=oh
            p+=esize
    def _parse_link(self, body):
        ver=body[0]; flags=body[1]; p=2
        if flags&0x08: p+=1
        if flags&0x04: p+=8
        if flags&0x10: p+=1
        lensz=1<<(flags&0x3)
        nlen=int.from_bytes(body[p:p+lensz],'little'); p+=lensz
        name=body[p:p+nlen].decode('ascii','replace'); p+=nlen
        addr=int.from_bytes(body[p:p+self.osz],'little')
        return name, addr
    # -------- dataset --------
    def read_dataset(self, oh_abs):
        msgs=self.obj_messages(oh_abs)
        dims=None; dt=None; layout=None; filters=[]
        for mt,body in msgs:
            if mt==0x01: dims=self._dataspace(body)
            elif mt==0x03: dt=self._datatype(body)
            elif mt==0x08: layout=self._layout(body)
            elif mt==0x0b: filters=self._filters(body)
        if dt is None or layout is None: return None
        npdt,elsz=dt
        if layout[0]=='contig':
            addr,size=layout[1],layout[2]
            if addr is None: return np.zeros(dims,npdt)
            raw=self._rd(self.ub+addr,size)
            arr=np.frombuffer(raw[:int(np.prod(dims))*elsz],npdt)
            return arr.reshape(dims) if dims else arr
        elif layout[0]=='chunk':
            return self._read_chunked(layout,dims,npdt,elsz,filters)
        elif layout[0]=='compact':
            raw=layout[1]
            arr=np.frombuffer(raw[:int(np.prod(dims))*elsz],npdt)
            return arr.reshape(dims) if dims else arr
    def _dataspace(self,body):
        ver=body[0]; ndim=body[1]; flags=body[2]
        if ver==1: p=8
        else: p=4
        dims=[]
        for i in range(ndim):
            dims.append(int.from_bytes(body[p:p+self.lsz],'little')); p+=self.lsz
        return tuple(dims)
    def _datatype(self,body):
        cls=body[0]&0xf; size=struct.unpack('<I',body[4:8])[0]
        if cls==1:
            npdt={4:'<f4',8:'<f8'}[size]
        elif cls==0:
            bf0=body[1]
            sign=bf0&0x08
            npdt={1:'i1',2:'<i2',4:'<i4',8:'<i8'}[size]
            if not sign: npdt=npdt.replace('i','u')
        else:
            npdt='V%d'%size
        return np.dtype(npdt),size
    def _layout(self,body):
        ver=body[0]
        if ver==3:
            cls=body[1]
            if cls==1:
                addr=int.from_bytes(body[2:2+self.osz],'little')
                size=int.from_bytes(body[2+self.osz:2+self.osz+self.lsz],'little')
                if addr==int.from_bytes(b'\xff'*self.osz,'little'): addr=None
                return ('contig',addr,size)
            elif cls==2:
                dimn=body[2]
                addr=int.from_bytes(body[3:3+self.osz],'little')
                p=3+self.osz
                cdims=[]
                for i in range(dimn):
                    cdims.append(struct.unpack('<I',body[p:p+4])[0]); p+=4
                return ('chunk',addr,tuple(cdims))
            elif cls==0:
                size=struct.unpack('<H',body[2:4])[0]
                return ('compact',body[4:4+size])
        elif ver in (1,2):
            cls=body[2]
            if cls==2:
                dimn=body[1]
                addr=int.from_bytes(body[8:8+self.osz],'little')
                p=8+self.osz; cdims=[]
                for i in range(dimn):
                    cdims.append(struct.unpack('<I',body[p:p+4])[0]); p+=4
                return ('chunk',addr,tuple(cdims))
            elif cls==1:
                addr=int.from_bytes(body[8:8+self.osz],'little')
                return ('contig',None if addr==int.from_bytes(b'\xff'*self.osz,'little') else addr, None)
        raise ValueError("layout ver %d"%ver)
    def _filters(self,body):
        ver=body[0]; n=body[1]; res=[]
        if ver==1: p=8
        else: p=2
        for i in range(n):
            fid=struct.unpack('<H',body[p:p+2])[0]
            if ver==1:
                namelen=struct.unpack('<H',body[p+2:p+4])[0]
                flags=struct.unpack('<H',body[p+4:p+6])[0]
                ncv=struct.unpack('<H',body[p+6:p+8])[0]
                p+=8+namelen+4*ncv
            else:
                if fid<256:
                    namelen=0; p+=2
                else:
                    namelen=struct.unpack('<H',body[p+2:p+4])[0]; p+=4
                flags=struct.unpack('<H',body[p:p+2])[0]; ncv=struct.unpack('<H',body[p+2:p+4])[0]; p+=4
                if namelen:
                    p+=namelen
                p+=4*ncv
            res.append(fid)
        return res
    def _read_chunked(self,layout,dims,npdt,elsz,filters):
        addr=layout[1]; cdims=layout[2][:-1]
        out=np.zeros(dims,npdt)
        if addr==int.from_bytes(b'\xff'*self.osz,'little'): return out
        chunks=[]
        self._walk_chunk_btree(self.ub+addr,len(dims),chunks)
        for coff,csize,fmask,rawaddr in chunks:
            raw=self._rd(self.ub+rawaddr,csize)
            data=raw
            for fid in reversed(filters):
                if fid==1: data=zlib.decompress(data)
                elif fid==2: data=self._unshuffle(data,elsz)
                elif fid==3: data=data[:-4]
            chunk=np.frombuffer(data,npdt)
            full=chunk.reshape(cdims)
            clip=tuple(slice(0,min(cdims[k],dims[k]-coff[k])) for k in range(len(dims)))
            target=tuple(slice(coff[k],coff[k]+(min(cdims[k],dims[k]-coff[k]))) for k in range(len(dims)))
            out[target]=full[clip]
        return out
    def _unshuffle(self,data,elsz):
        n=len(data)//elsz
        a=np.frombuffer(data[:n*elsz],dtype='u1').reshape(elsz,n)
        return a.T.tobytes()+data[n*elsz:]
    def _walk_chunk_btree(self,bt_abs,ndim,chunks):
        d=self._rd(bt_abs,8)
        if d[:4]!=b'TREE': return
        node_type=d[4]; level=d[5]; entries=struct.unpack('<H',d[6:8])[0]
        p=bt_abs+8+2*self.osz
        keysz=8+(ndim+1)*8
        for i in range(entries):
            key=self._rd(p,keysz); p+=keysz
            csize=struct.unpack('<I',key[:4])[0]
            fmask=struct.unpack('<I',key[4:8])[0]
            offs=[struct.unpack('<Q',key[8+8*k:16+8*k])[0] for k in range(ndim)]
            child=int.from_bytes(self._rd(p,self.osz),'little'); p+=self.osz
            if level>0:
                self._walk_chunk_btree(self.ub+child,ndim,chunks)
            else:
                chunks.append((offs,csize,fmask,child))
    def get(self, path):
        oh=self.addr(self.root_oh)
        parts=[x for x in path.split('/') if x]
        for i,part in enumerate(parts):
            mem=self.group_members(oh)
            if part not in mem: raise KeyError(part+" ; have: "+",".join(list(mem)[:20]))
            oh=self.ub+mem[part]
        return oh
    def read(self,path):
        return self.read_dataset(self.get(path))
    def ls(self,path=''):
        oh=self.get(path) if path else self.addr(self.root_oh)
        return self.group_members(oh)

if __name__=='__main__':
    import sys
    h=H5File(sys.argv[1])
    print("root:",list(h.ls()))
