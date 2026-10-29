/* SPDX-License-Identifier: GPL-3.0-or-later
 * Real frame processing without Resolve/FUSE: isolates engine costs.
 * Usage: frame_benchmark SOURCE_DIR MODE BAD_PIX FOCUS_PIX CLIPS FRAMES INDEX_DIR FPM_DIR
 * MODE: 0 raw / 1 preview / 2 grading. No writes beside source clips.
 */
#define main mlvfs_program_main
#include "../mlvfs/main.c"
#undef main
#include <assert.h>
#include <time.h>
static double seconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static int compare_double(const void *a,const void *b) { double x=*(const double*)a,y=*(const double*)b; return (x>y)-(x<y); }
int main(int argc,char **argv) {
    if(argc!=9) { fprintf(stderr,"usage: %s SOURCE MODE BAD FOCUS CLIPS FRAMES INDEX FPM\n",argv[0]); return 2; }
    mlvfs.mlv_path=argv[1]; mlvfs.name_scheme=1;
    int mode=atoi(argv[2]), limit=atoi(argv[5]), frames=atoi(argv[6]);
    mlvfs.fix_bad_pixels=atoi(argv[3]); mlvfs.no_focus_pixels=!atoi(argv[4]);
    mlvfs_index_dir=argv[7]; mlvfs.fpm_dir=argv[8];
    dual_iso_switch_init(mode);
    char *names[256]; int counts[256],clips=0;
    struct dirent **entries; int count=scandir(argv[1],&entries,NULL,alphasort);
    if(count<0 || frames<1 || limit<1 || limit>256) return 2;
    for(int i=0;i<count;i++) {
        if(clips<limit && (string_ends_with(entries[i]->d_name,".MLV") || string_ends_with(entries[i]->d_name,".mlv"))) {
            char *path=path_append(argv[1],entries[i]->d_name),*base=NULL;
            if(get_mlv_basename(path,&base)) {
                int frame_count=mlv_get_frame_count(path);
                if(frame_count>0) { names[clips]=base; counts[clips]=frame_count; clips++; }
                else free(base);
            }
            free(path);
        }
        free(entries[i]);
    }
    free(entries);
    if(!clips) return 3;
    double *times=calloc(frames,sizeof(double)); int done=0; size_t bytes=0;
    double start=seconds();
    for(int i=0;i<frames;i++) {
        int c=i%clips, frame=(i/clips)%counts[c];
        char path[4096]; snprintf(path,sizeof(path),"/%s/%s_%06d.dng",names[c],names[c],frame);
        struct image_buffer image={0}; image.dng_filename=path;
        double t=seconds(); int ok=process_frame(&image); times[i]=seconds()-t;
        if(!ok || !image.data || !image.header) { fprintf(stderr,"FAILED %s\n",path); return 4; }
        bytes+=image.size; done++; free(image.data); free(image.header);
    }
    double elapsed=seconds()-start;
    qsort(times,frames,sizeof(double),compare_double);
    fprintf(stderr,"BENCH mode=%d bad=%d focus=%d clips=%d frames=%d seconds=%.3f fps=%.2f median_ms=%.2f p95_ms=%.2f MBps=%.2f\n",mode,mlvfs.fix_bad_pixels,!mlvfs.no_focus_pixels,clips,done,elapsed,done/elapsed,times[frames/2]*1000,times[(frames-1)*95/100]*1000,bytes/elapsed/1e6);
    for(int i=0;i<clips;i++) free(names[i]); free(times); return 0;
}
