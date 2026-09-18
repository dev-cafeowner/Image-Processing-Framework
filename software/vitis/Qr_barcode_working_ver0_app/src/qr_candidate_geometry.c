#include "qr_candidate_geometry.h"
#include <math.h>
#include <string.h>

static int clamp(int x,int a,int b) {return x<a?a:(x>b?b:x);}
static double distance2(const qr_candidate_t *a,const qr_candidate_t *b) {
    double dx=(double)(a->sum_x/a->hits)-(double)(b->sum_x/b->hits);
    double dy=(double)(a->sum_y/a->hits)-(double)(b->sum_y/b->hits);
    return dx*dx+dy*dy;
}
int qr_candidate_geometry_ex(const qr_candidate_packet_t *p,uint32_t frame_id,
    qr_geometry_proposal_t out[QR_GEOMETRY_MAX_PROPOSALS], qr_geometry_diagnostics_t *diagnostics)
{
    qr_geometry_diagnostics_t local;
    qr_geometry_diagnostics_t *diag=diagnostics ? diagnostics:&local;
    const qr_candidate_t *best[6];
    int n=0,count=0,i,j,k;
    memset(diag,0,sizeof(*diag));
    if(p) diag->input_count=p->count;
    if(!p || !out || p->frame_id!=frame_id || p->count>16) {diag->invalid=1;return 0;}
    if(p->count<3) return 0;
    /* Bounded top-six selection, strongest duplicate retained. Caller must
     * already validate QRP1; repeat divisors/bounds here for API robustness. */
    for(i=0;i<(int)p->count;++i) {
        const qr_candidate_t *c=&p->items[i];
        int pos=n,duplicate=-1;
        if(c->hits<3 || c->hits>256 || c->sum_x/c->hits>=640 || c->sum_y/c->hits>=480 ||
           c->min_y>c->max_y || c->max_y>=480) {diag->invalid=1;return 0;}
        for(j=0;j<n;++j) if(distance2(c,best[j])<64) {duplicate=j;break;}
        if(duplicate>=0) {
            if(c->hits<=best[duplicate]->hits) continue;
            for(j=duplicate;j<n-1;++j) best[j]=best[j+1];
            --n;pos=n;
        }
        for(j=0;j<n;++j) if(c->hits>best[j]->hits) {pos=j;break;}
        if(pos>=6) continue;
        if(n<6) ++n;
        for(j=n-1;j>pos;--j) best[j]=best[j-1];
        best[pos]=c;
    }
    diag->filtered_count=n;
    for(i=0;i<n;++i) for(j=i+1;j<n;++j) for(k=j+1;k<n;++k) {
        const qr_candidate_t *c[3]={best[i],best[j],best[k]};
        double d01=distance2(c[0],c[1]),d02=distance2(c[0],c[2]),d12=distance2(c[1],c[2]);
        int pivot=d12>=d01 && d12>=d02 ? 0 : (d02>=d01 ? 1:2);
        const qr_candidate_t *t[3]={c[pivot],c[(pivot+1)%3],c[(pivot+2)%3]};
        double a=distance2(t[0],t[1]),b=distance2(t[0],t[2]);
        double short2=a<b?a:b,long2=a>b?a:b,dot;
        qr_geometry_proposal_t proposal;
        int x[4],y[4],q,lo_x=640,lo_y=480,hi_x=0,hi_y=0,pad,pos;
        unsigned min_span=480,max_span=0;
        ++diag->triplets;
        if(short2<24.0*24.0 || long2>short2*6.25) {++diag->spacing_reject;continue;}
        memset(&proposal,0,sizeof(proposal));
        for(q=0;q<3;++q) {
            unsigned span=t[q]->max_y-t[q]->min_y+1;
            if(span<min_span) min_span=span;
            if(span>max_span) max_span=span;
            x[q]=(int)(t[q]->sum_x/t[q]->hits); y[q]=(int)(t[q]->sum_y/t[q]->hits);
            proposal.roi.seed[q].x=x[q];proposal.roi.seed[q].y=y[q];
            proposal.roi.seed[q].radius=clamp((int)span/3,QR_GUIDED_SEED_RADIUS_MIN,12);
            proposal.labels[q]=t[q]->label;
        }
        /* HIT span is only a consistency cue, not a module-size estimate. */
        if(max_span>4*min_span || short2<4.0*max_span*max_span) {++diag->span_reject;continue;}
        dot=(double)(x[1]-x[0])*(x[2]-x[0])+(double)(y[1]-y[0])*(y[2]-y[0]);
        if(dot*dot>0.36*a*b) {++diag->angle_reject;continue;}
        proposal.score=dot*dot/(a*b)+0.15*(long2/short2-1.0);
        x[3]=x[1]+x[2]-x[0];y[3]=y[1]+y[2]-y[0];
        for(q=0;q<4;++q) {
            if(x[q]<lo_x)lo_x=x[q];
            if(x[q]>hi_x)hi_x=x[q];
            if(y[q]<lo_y)lo_y=y[q];
            if(y[q]>hi_y)hi_y=y[q];
        }
        /* 0.55 covers the V1 7.5-module outer finder+quiet margin over
         * 14-module center spacing; conservatively clamped to this frame. */
        pad=(int)ceil(0.55*sqrt(long2))+4;
        proposal.roi.x0=clamp(lo_x-pad,0,639);proposal.roi.x1=clamp(hi_x+pad+1,1,640);
        proposal.roi.y0=clamp(lo_y-pad,0,479);proposal.roi.y1=clamp(hi_y+pad+1,1,480);
        proposal.roi.search_half_width=clamp((int)sqrt(short2)/2+8,12,320);
        pos=count;
        for(q=0;q<count;++q) if(proposal.score<out[q].score) {pos=q;break;}
        if(pos>=QR_GEOMETRY_MAX_PROPOSALS)continue;
        if(count<QR_GEOMETRY_MAX_PROPOSALS)++count;
        for(q=count-1;q>pos;--q)out[q]=out[q-1];
        out[pos]=proposal;
    }
    return count;
}
int qr_candidate_geometry(const qr_candidate_packet_t *p,uint32_t frame_id,
    qr_geometry_proposal_t out[QR_GEOMETRY_MAX_PROPOSALS])
{
    return qr_candidate_geometry_ex(p,frame_id,out,NULL);
}
