// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * enactor_helper.cuh
 *
 * @brief helper functions for enactor base
 */

#pragma once

#include <gunrock/app/enactor_slice.cuh>

namespace gunrock {
namespace app {

template <typename ThreadSlice>
bool All_Done(typename ThreadSlice::Enactor *enactor,
              int      gpu_num  = 0)
{
    typedef typename ThreadSlice::Enactor Enactor;
    //printf("All_Done begin. gpu_num = %d\n", gpu_num); fflush(stdout);

    EnactorSlice<Enactor> *enactor_slices 
        = (EnactorSlice<Enactor>*) enactor->enactor_slices;
    ThreadSlice *thread_slices = (ThreadSlice*) enactor->thread_slices;
    
    for (int i=0; i<enactor->num_threads; i++)
    {
        cudaError_t retval = thread_slices[i].retval;
        if (retval == cudaSuccess) continue;
        printf("(CUDA error %d @ GPU %d, thread %d: %s\n",
            retval, thread_slices[i].gpu_num, 
            thread_slices[i].thread_num,
            cudaGetErrorString(retval)); 
        fflush(stdout);
        return true;
    }   

    for (int gpu=0; gpu < enactor->num_gpus; gpu++)
    {
        EnactorSlice<Enactor> *enactor_slice = &enactor_slices[gpu];
        for (int stream=0; stream < enactor->num_subq__streams + enactor->num_fullq_stream ; stream++)
        {
            typename Enactor::FrontierA *frontier_attribute = (stream < enactor->num_subq__streams) ? 
                enactor_slice->subq__frontier_attributes + stream :
                enactor_slice->fullq_frontier_attribute  + stream - enactor->num_subq__streams;
            if (frontier_attribute->queue_length != 0 ||
                frontier_attribute->has_incoming)
            {
                printf("gpu %d : frontier_attribute[%d].queue_length = %d\n",
                    gpu, stream, frontier_attribute -> queue_length);   
                fflush(stdout);
                return false;
            }
        }

        for (int i=0; i<2; i++)
        if (!enactor_slice -> input_queues[i].Empty())
        {
            printf("gpu %d : input_queues[%d] not empty\n", gpu, i);
            fflush(stdout);
            return false;
        }

        if (!enactor_slice -> outpu_queue.Empty())
        {
            printf("gpu %d : outpu_queue not empty\n", gpu);
            fflush(stdout);
            return false;
        }

        if (!enactor_slice -> subq__queue.Empty())
        {
            printf("gpu %d : subq__queue not empty\n", gpu);
            fflush(stdout);
            return false;
        }

        if (!enactor_slice -> fullq_queue.Empty())
        {
            printf("gpu %d : fullq_queue not empty\n", gpu);
            fflush(stdout);
            return false;
        }
    }

    printf("All_Done return true. gpu_num = %d\n", gpu_num); fflush(stdout);
    return true;
} 

template <
    bool     SIZE_CHECK,
    typename SizeT,
    typename Type>
cudaError_t Check_Size(
    const char *name,
    SizeT       target_length,
    util::Array1D<SizeT, Type> 
               *array,
    bool       &oversized,
    int         gpu_num      = -1,
    int         iteration    = -1,
    int         stream_num   = -1,
    bool        keep_content = false)
{
    cudaError_t retval = cudaSuccess;

    if (target_length > array->GetSize())
    {
        printf("%d\t %d\t %d\t %s \t oversize :\t %d ->\t %d\n",
            gpu_num, iteration, stream_num, name,
            array->GetSize(), target_length);
        fflush(stdout);
        oversized=true;
        if (SIZE_CHECK)
        {
            if (array->GetSize() != 0) retval = array->EnsureSize(target_length, keep_content);
            else retval = array->Allocate(target_length, util::DEVICE);
        } else {
            char temp_str[]=" oversize", str[256];
            memcpy(str, name, sizeof(char) * strlen(name));
            memcpy(str + strlen(name), temp_str, sizeof(char) * strlen(temp_str));
            str[strlen(name)+strlen(temp_str)]='\0';
            retval = util::GRError(cudaErrorLaunchOutOfResources, str, __FILE__, __LINE__);
        }
    }
    return retval;
}

template <typename Enactor>
cudaError_t PushNeibor(
    typename Enactor::PRequest *request,
    Enactor           *enactor)
{
    typedef typename Enactor::SizeT         SizeT;
    typedef typename Enactor::VertexId      VertexId;
    typedef typename Enactor::Value         Value;
    typedef EnactorSlice<Enactor>  EnactorSlice;
    typedef typename Enactor::CircularQueue CircularQueue;

    int            s_gpu_num             =   request -> gpu_num;
    int            t_gpu_num             =   request -> peer;
    long long      iteration             =   request -> iteration;
    SizeT          length                =   request -> length;
    EnactorSlice  *enactor_slices        = (EnactorSlice*) enactor->enactor_slices;
    EnactorSlice  *s_enactor_slice       = &(enactor_slices[s_gpu_num]);
    EnactorSlice  *t_enactor_slice       = &(enactor_slices[t_gpu_num]);
    CircularQueue *s_queue               = &(s_enactor_slice -> outpu_queue);             // source output cq
    CircularQueue *t_queue               = &(t_enactor_slice -> input_queues[(iteration+1)%2]); // target input cq
    SizeT          num_vertex_associates =   request -> num_vertex_associates;
    SizeT          num_value__associates =   request -> num_value__associates;
    VertexId      *s_vertices            =   request -> vertices;
    VertexId     **s_vertex_associates   =   request -> vertex_associates;
    Value        **s_value__associates   =   request -> value__associates;
    cudaEvent_t    event                 =   request -> event;
    VertexId      *t_vertices            =   NULL;
    VertexId      *t_vertex_associates[Enactor::NUM_VERTEX_ASSOCIATES];
    Value         *t_value__associates[Enactor::NUM_VALUE__ASSOCIATES];
    SizeT          s_offset              =   request -> offset;
    SizeT          t_offset              =   0;
    cudaError_t    retval                =   cudaSuccess;
    cudaStream_t   s_stream              =   request -> stream;
    cudaStream_t   t_stream              =   t_enactor_slice -> input_streams[0];

    printf("%d\t %lld\t \t PushNeibor\t To %d, length = %d\n",
        request -> gpu_num, iteration, request -> peer, length);
    fflush(stdout);

    if (length > 0)
        if (retval = util::GRError(cudaStreamWaitEvent(s_stream, event, 0),
            "cudaStreamWaitEvent failed", __FILE__, __LINE__)) return retval;

    //util::cpu_mt::PrintGPUArray<SizeT, VertexId>("pushing keys", s_vertices, length, request->gpu_num, iteration, request -> peer, s_stream);
    //util::cpu_mt::PrintGPUArray<SizeT, VertexId>("pushing labels", s_vertex_associates[0], length, request->gpu_num, iteration, request -> peer, s_stream);

    if (retval = t_queue->Push_Addr(length, t_vertices, t_offset, 
        num_vertex_associates, num_value__associates, 
        t_vertex_associates, t_value__associates, true)) return retval;

    if (length > 0)
    {
        if (retval = util::GRError(cudaMemcpyAsync(
            t_vertices, s_vertices, sizeof(VertexId) * length,
            cudaMemcpyDefault, s_stream),
            "cudaMemcpyAsync vertices failed", __FILE__, __LINE__)) return retval;

        for (SizeT i=0; i<num_vertex_associates; i++)
        {
            if (retval = util::GRError(cudaMemcpyAsync(
                t_vertex_associates[i], s_vertex_associates[i], sizeof(VertexId) * length,
                cudaMemcpyDefault, s_stream),
                "cudaMemcpyAsync vertex_associates failed", __FILE__, __LINE__)) return retval;
        }

        for (SizeT i=0; i<num_value__associates; i++)
        {
            if (retval = util::GRError(cudaMemcpyAsync(
                t_value__associates[i], s_value__associates[i], sizeof(VertexId) * length,
                cudaMemcpyDefault, s_stream),
                "cudaMemcpyAsync value__associates failed", __FILE__, __LINE__)) return retval;
        }

        if (retval = s_queue->EventSet(0, s_offset, length, s_stream)) return retval;
        if (retval = s_queue->EventSet(1, s_offset, length, s_stream)) return retval;
        if (retval = t_queue->EventSet(0, t_offset, length, t_stream, false, true)) return retval;
    } else {
        if (retval = s_queue->EventFinish(0, s_offset, length, s_stream)) return retval;
        if (retval = s_queue->EventFinish(1, s_offset, length, s_stream)) return retval;
        if (retval = t_queue->EventFinish(0, t_offset, length, t_stream)) return retval;
    }
    return retval;
}

template <typename Enactor>
void ShowDebugInfo(
    int           gpu_num,
    int           thread_type, // 0:input, 1:output, 2:subq, 3:fullq
    int           thread_num,
    int           stream_num,
    Enactor      *enactor,
    long long     iteration,
    std::string   check_name = "",
    cudaStream_t  stream = 0) 
{    
    typedef typename Enactor::SizeT    SizeT;
    typedef typename Enactor::VertexId VertexId;
    typedef typename Enactor::Value    Value;
    SizeT queue_length = -1;
    int   stage        = -1;

    EnactorSlice<Enactor> *enactor_slice 
        = ((EnactorSlice<Enactor>*) enactor->enactor_slices) + gpu_num;
    //util::cpu_mt::PrintMessage(check_name.c_str(), thread_num, enactor_stats->iteration);
    //printf("%d \t %d\t \t reset = %d, index = %d\n",thread_num, enactor_stats->iteration, frontier_attribute->queue_reset, frontier_attribute->queue_index);fflush(stdout);
    //if (frontier_attribute->queue_reset)
    switch (thread_type)
    {
    case 0:
        break;
    case 1:
        break;
    case 2:
        queue_length = enactor_slice->subq__frontier_attributes[stream_num].queue_length;
        stage        = enactor_slice->subq__stages    [stream_num];
        break;
    case 3:
        queue_length = enactor_slice->fullq_frontier_attribute [stream_num].queue_length;
        stage        = enactor_slice->fullq_stage     [stream_num];
        break;
    default:
        break;
    }
    //else if (enactor_stats->retval = util::GRError(work_progress->GetQueueLength(frontier_attribute->queue_index, queue_length, false, stream), "work_progress failed", __FILE__, __LINE__)) return;
    //util::cpu_mt::PrintCPUArray<SizeT, SizeT>((check_name+" Queue_Length").c_str(), &(queue_length), 1, thread_num, enactor_stats->iteration);
    printf("%d\t %lld\t %d\t stage%d\t %s\t Queue_Length = %d\n", 
        gpu_num, iteration, stream_num, 
        stage, check_name.c_str(), queue_length);fflush(stdout);
    //printf("%d \t %d\t \t peer_ = %d, selector = %d, length = %d, p = %p\n",thread_num, enactor_stats->iteration, peer_, frontier_attribute->selector,queue_length,graph_slice->frontier_queues[peer_].keys[frontier_attribute->selector].GetPointer(util::DEVICE));fflush(stdout);
    //util::cpu_mt::PrintGPUArray<SizeT, VertexId>((check_name+" keys").c_str(), data_slice->frontier_queues[peer_].keys[frontier_attribute->selector].GetPointer(util::DEVICE), queue_length, thread_num, enactor_stats->iteration,peer_, stream);
    //if (graph_slice->frontier_queues.values[frontier_attribute->selector].GetPointer(util::DEVICE)!=NULL)
    //    util::cpu_mt::PrintGPUArray<SizeT, Value   >("valu1", graph_slice->frontier_queues.values[frontier_attribute->selector].GetPointer(util::DEVICE), _queue_length, thread_num, enactor_stats->iteration);
    //util::cpu_mt::PrintGPUArray<SizeT, VertexId>("degrees", data_slice->degrees.GetPointer(util::DEVICE), graph_slice->nodes, thread_num, enactor_stats->iteration);
    //if (BFSProblem::MARK_PREDECESSORS)
    //    util::cpu_mt::PrintGPUArray<SizeT, VertexId>("pred1", data_slice[0]->preds.GetPointer(util::DEVICE), graph_slice->nodes, thread_num, enactor_stats->iteration);
    //if (BFSProblem::ENABLE_IDEMPOTENCE)
    //    util::cpu_mt::PrintGPUArray<SizeT, unsigned char>("mask1", data_slice[0]->visited_mask.GetPointer(util::DEVICE), (graph_slice->nodes+7)/8, thread_num, enactor_stats->iteration);
}  

template <typename EnactorSlice>
cudaError_t Set_Record(
    EnactorSlice *enactor_slice,
    int thread_type,
    int iteration,
    int stream_num,
    int stage)
{
    cudaError_t retval = cudaSuccess;
    if (thread_type == 2) // subq
    {
        //printf("subq__events = %d, event_set = %s\n",
        //    enactor_slice -> subq__events[iteration%4][stream_num][stage],
        //    enactor_slice -> subq__event_sets[iteration%4][stream_num][stage] ? "true" : "false"); fflush(stdout);
        retval = cudaEventRecord(
            enactor_slice -> subq__events[iteration%4][stream_num][stage],
            enactor_slice -> subq__streams[stream_num]);
        enactor_slice -> subq__event_sets[iteration%4][stream_num][stage] = true;
    } else if (thread_type == 3) // fullq
    {
        retval = cudaEventRecord(
            enactor_slice -> fullq_event [iteration%4][stream_num][stage],
            enactor_slice -> fullq_stream[stream_num]);
        enactor_slice -> fullq_event_set [iteration%4][stream_num][stage] = true;
    }
    return retval;
}

template <typename EnactorSlice>
cudaError_t Check_Record(
    EnactorSlice *enactor_slice,
    int thread_type,
    int iteration,
    int stream_num,
    int stage_to_check,
    int &stage,
    bool &to_show)
{
    cudaError_t retval = cudaSuccess;
    to_show = true;
    bool *event_set = NULL;
    cudaEvent_t event;

    if (thread_type == 2) 
    { // subq
        event     = enactor_slice ->
            subq__events    [iteration%4][stream_num][stage_to_check];
        event_set = enactor_slice -> 
            subq__event_sets[iteration%4][stream_num] + stage_to_check;
    } else if (thread_type == 3) 
    { // fullq
        event     = enactor_slice ->
            fullq_event     [iteration%4][stream_num][stage_to_check];
        event_set = enactor_slice ->
            fullq_event_set [iteration%4][stream_num] + stage_to_check;
    }
    if (!event_set[0])
    {   
        to_show = false;
    } else {
        retval = cudaEventQuery(event);
        if (retval == cudaErrorNotReady)
        {   
            to_show=false;
            retval = cudaSuccess; 
        } else if (retval == cudaSuccess)
        {
            event_set[0] = false;
        }
    }
    return retval;
}

} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
