#include "rc4.h"
/************************************************************************/
/* 
������˼·��ÿ�λ�ȡһ����Կ�����ܶ�Ӧ�����ģ����õ��������Ƿ�����ĳ��������
���ǹ�������Ҫ���м����̫���ˣ�ת��һ�룬���ĺ����������Ĺ�ϵ����ô��֪��
�ĺ��������Ļ����ܵõ���Կ����ĳЩλ�õ�ֵ�������Ϳ���ʡȥ���ٿռ�~~
*/
/************************************************************************/
/** 
 * \brief,to generate the candidate key 
 **/
__device__ bool generateKey(int startIndex)
{
	unsigned char currentkeyLen=shared_mem[startIndex+KEY_LEN_OFFSET],tempP=currentkeyLen;
	if(currentkeyLen<MAX_KEY_LENGTH)
	{
		shared_mem[startIndex+currentkeyLen]++;
		while(shared_mem[startIndex+tempP]>END_CHARACTER&&tempP>0)
		{
			shared_mem[startIndex+tempP]=START_CHARACTER;
			tempP--;
			shared_mem[startIndex+tempP]++;
		}
		if(shared_mem[startIndex]>END_CHARACTER)
		{
			currentkeyLen++;
			shared_mem[startIndex]=START_CHARACTER;
			shared_mem[startIndex+currentkeyLen]=START_CHARACTER;
		}
		shared_mem[startIndex+KEY_LEN_OFFSET]=currentkeyLen;
		shared_mem[startIndex+currentkeyLen+1]='\0';
		return true;
	}
	return false;
}

__device__ unsigned char* genKey(unsigned char*res,unsigned long long val,int*key_len)
{
	char p=MAX_KEY_LENGTH-1;
	while (val&&p>=0) {
		res[p--] = (val - 1) % KEY + START_CHARACTER;
		val = (val - 1) / KEY;
	}
	*key_len=(MAX_KEY_LENGTH-p-1);
	return res+p+1;
}

__global__ void crackRc4Kernel(unsigned char*key, volatile bool *found)
{
	if(*found) asm("exit;");

	int bdx=blockIdx.x, tid=threadIdx.x, keyLen=0;

	const unsigned long long cycleNum=maxNum/(gridDim.x*blockDim.x*OPERATE_KEY_PER_THREAD);

	unsigned long long startPoint;
	bool justIt=true;

	unsigned char tempArray[MAX_KEY_LENGTH+1];
	unsigned char * vKey;

	for (unsigned long long i=0;i<=cycleNum&startPoint<maxNum;i++)
	{
		if(*found) asm("exit;");

		startPoint=i*(gridDim.x*blockDim.x*OPERATE_KEY_PER_THREAD);
		if(startPoint==0) startPoint=1;
		vKey=genKey(tempArray,startPoint,&keyLen);
		memcpy((shared_mem+MEMEORY_PER_THREAD*tid),vKey,keyLen);
		keyLen--;
		shared_mem[MEMEORY_PER_THREAD*tid+KEY_LEN_OFFSET]=keyLen;
		for (int j=0;j<OPERATE_KEY_PER_THREAD;j++)
		{
			if(*found) asm("exit;");
			if(j!=0) generateKey(MEMEORY_PER_THREAD*tid);

			keyLen=shared_mem[MEMEORY_PER_THREAD*tid+KEY_LEN_OFFSET];
			vKey=shared_mem+MEMEORY_PER_THREAD*tid;

			if(*found) asm("exit;");

			justIt=device_isKeyRight(vKey,keyLen+1,found);

			//��ǰ��Կ��������
			if (!justIt) continue;

			//�ҵ��Ļ��˳�
			if(*found) asm("exit;");

			//�ҵ�ƥ����Կ��д��Host����������,�޸�found,�˳�����
			*found=true;
			memcpy(key,vKey,keyLen+1);
			key[keyLen+1]=0;
			__threadfence();
			asm("exit;");
			break;
		}		
	}
}

// Helper function for using CUDA to add vectors in parallel.
cudaError_t crackRc4WithCuda(unsigned char* knownKeyStream_host, int knownStreamLen_host, unsigned char*key, bool*found)
{
	unsigned char *key_dev ;
	bool* found_dev;
	cudaError_t cudaStatus;


	// Choose which GPU to run on, change this on a multi-GPU system.
	cudaStatus = cudaSetDevice(0);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaSetDevice failed!  Do you have a CUDA-capable GPU installed?");
		goto Error;
	}

	cudaDeviceProp prop;
	cudaGetDeviceProperties(&prop, 0);

	cudaStatus = cudaMalloc((void**)&key_dev, (MAX_KEY_LENGTH+1) * sizeof(unsigned char));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!");
		goto Error;
	}

	cudaStatus = cudaMalloc((void**)&found_dev, sizeof(bool));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!");
		goto Error;
	}

	//�����Ƿ��ҵ���Կ����
	cudaStatus = cudaMemcpy(found_dev, found, sizeof(bool), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!");
		goto Error;
	}

	//���Ƴ����ڴ�
	cudaStatus = cudaMemcpyToSymbol(knowStream_device, knownKeyStream_host,sizeof(unsigned char)*knownStreamLen_host);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpyToSymbol failed!");
		goto Error;
	}

	cudaStatus = cudaMemcpyToSymbol((const void *)&knownStreamLen_device,(const void *)&knownStreamLen_host,sizeof(unsigned char));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpyToSymbol failed!");
		goto Error;
	}

	// Launch a kernel on the GPU with one thread for each element.
	int threadNum=floor((double)(prop.sharedMemPerBlock/MEMEORY_PER_THREAD)),share_memory=prop.sharedMemPerBlock;
	if(threadNum>MAX_THREAD_NUM){
		threadNum=MAX_THREAD_NUM;
		share_memory=threadNum*MEMEORY_PER_THREAD;
	}
	crackRc4Kernel<<<BLOCK_NUM, threadNum, share_memory>>>(key_dev,found_dev);

	// Check for any errors launching the kernel
	cudaStatus = cudaGetLastError();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "addKernel launch failed: %s\n", cudaGetErrorString(cudaStatus));
		goto Error;
	}

	// cudaDeviceSynchronize waits for the kernel to finish, and returns
	// any errors encountered during the launch.
	cudaStatus = cudaDeviceSynchronize();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching addKernel!\n", cudaStatus);
		goto Error;
	}

	// Copy output vector from GPU buffer to host memory.
	cudaStatus = cudaMemcpy(key, key_dev, (MAX_KEY_LENGTH+1) * sizeof(unsigned char), cudaMemcpyDeviceToHost);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!");
		goto Error;
	}

	// Copy output vector from GPU buffer to host memory.
	cudaStatus = cudaMemcpy(found, found_dev,  sizeof(bool), cudaMemcpyDeviceToHost);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!");
		goto Error;
	}

Error:
	cudaFree(key_dev);
	cudaFree(found_dev);

	return cudaStatus;
}

int main(int argc, char *argv[])
{
//	printf("%c",0x7d);
	unsigned char* s_box = (unsigned char*)malloc(sizeof(unsigned char)*256);
	//��Կ
	unsigned char encryptKey[]="!}";
	//����
	unsigned char buffer[] = "Life is a chain of moments of enjoyment, not only about survivalO(��_��)O~";
	int buffer_len=strlen((char*)buffer);
	prepare_key(encryptKey,strlen((char*)encryptKey),s_box);
	rc4(buffer,buffer_len,s_box);	

	unsigned char knownPlainText[]="Life";
	int known_p_len=strlen((char*)knownPlainText);
	unsigned char* knownKeyStream=(unsigned char*)malloc(sizeof(unsigned char)*known_p_len);
	for (int i=0;i<known_p_len;i++)
	{
		knownKeyStream[i]=knownPlainText[i]^buffer[i];
	}

	unsigned char * key=(unsigned char*)malloc( sizeof(unsigned char) * (MAX_KEY_LENGTH+1));

	cudaEvent_t start,stop;
	cudaError_t cudaStatus=cudaEventCreate(&start);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaEventCreate(start) failed!");
		return 1;
	}
	cudaStatus=cudaEventCreate(&stop);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaEventCreate(stop) failed!");
		return 1;
	}

	cudaStatus=cudaEventRecord(start,0);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaEventRecord(start) failed!");
		return 1;
	}

	bool found=false;
	cudaStatus = crackRc4WithCuda(knownKeyStream, known_p_len , key, &found);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "addWithCuda failed!");
		return 1;
	}

	cudaStatus=cudaEventRecord(stop,0);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaEventRecord(stop) failed!");
		return 1;
	}

	cudaStatus=cudaEventSynchronize(stop);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaEventSynchronize failed!");
		return 1;
	}
	float useTime;
	cudaStatus=cudaEventElapsedTime(&useTime,start,stop);
	useTime/=1000;
	printf("The time we used was:%fs\n",useTime);
	if (found)
	{
		printf("The right key has been found.The right key is:%s\n",key);
		prepare_key(key,strlen((char*)key),s_box);
		rc4(buffer,buffer_len,s_box);
		printf ("\nThe clear text is:\n%s\n",buffer);
	}

	cudaEventDestroy(start);
	cudaEventDestroy(stop);

	free(key);
	free(knownKeyStream);
	free(s_box);
	cudaThreadExit();
	return 0;
}



